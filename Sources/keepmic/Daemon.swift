import CoreAudio
import Foundation

/// The core guard. Event-driven: subscribes to CoreAudio default-input and
/// device-list changes and re-pins the default input whenever a Bluetooth
/// device takes it over. No polling.
final class Daemon {
    private let queue = DispatchQueue(label: "keepmic.daemon")
    /// Pending post-pause recheck. Only touched on `queue`, so no locking needed.
    private var pauseRecheck: DispatchWorkItem?

    func run() -> Never {
        log("keepmic \(Version.current) started — keeping the default input off Bluetooth devices")

        // Strong captures are intentional: the listener blocks (retained by
        // CoreAudio) keep the daemon alive for the lifetime of the process.
        AudioSystem.addListener(kAudioHardwarePropertyDefaultInputDevice, queue: queue) {
            self.enforce(trigger: "default input changed")
        }
        AudioSystem.addListener(kAudioHardwarePropertyDevices, queue: queue) {
            self.enforce(trigger: "device list changed")
        }

        queue.async { self.enforce(trigger: "startup") }
        dispatchMain()
    }

    /// One-shot enforcement, also used by `keepmic resume` from the CLI.
    ///
    /// Three rules, in order:
    /// 1. If the preferred device (`keepmic prefer`) is connected, it must be
    ///    the default input. A preferred mic always wins while present.
    /// 2. Otherwise, if wired earbuds or a wired headset are plugged in, their
    ///    mic takes over from a Bluetooth mic or the Mac's internal mic.
    /// 3. Otherwise, if a Bluetooth device holds the default input, pin it
    ///    back to the best physical mic.
    @discardableResult
    static func enforceOnce(reportSkips: Bool = false) -> Bool {
        guard let current = AudioSystem.defaultInput else { return false }
        let nonBluetooth = AudioSystem.inputDevices.filter { !$0.isBluetooth }

        if let preferred = connectedPreferred(among: nonBluetooth) {
            guard preferred != current else { return false }
            guard AudioSystem.setDefaultInput(preferred) else {
                log("failed to set default input to \(quoted(preferred.name))")
                return false
            }
            log("default input was \(quoted(current.name)) — switched to preferred \(quoted(preferred.name))")
            return true
        }

        if current.isBluetooth || current.isInternalMic,
           !current.isWiredHeadsetMic,
           let headset = nonBluetooth.filter({ $0.isWiredHeadsetMic }).min(by: { $0.name < $1.name }) {
            guard AudioSystem.setDefaultInput(headset) else {
                log("failed to set default input to \(quoted(headset.name))")
                return false
            }
            log("default input was \(quoted(current.name)) (\(current.transportName)), switched to wired headset mic \(quoted(headset.name))")
            return true
        }

        guard current.isBluetooth else { return false }
        let physical = nonBluetooth.filter { !$0.isVirtual }
        guard let target = physical.min(by: { ($0.fallbackRank, $0.name) < ($1.fallbackRank, $1.name) }) else {
            if reportSkips {
                log("default input is \(quoted(current.name)) but no physical non-Bluetooth mic is available — leaving it")
            }
            return false
        }
        guard AudioSystem.setDefaultInput(target) else {
            log("failed to set default input to \(quoted(target.name))")
            return false
        }
        log("default input was \(quoted(current.name)) (bluetooth) — pinned back to \(quoted(target.name))")
        return true
    }

    /// One row of the input priority list, in the order keepmic picks mics.
    struct PriorityEntry {
        enum Role { case preferred, wiredHeadset, fallback }
        let name: String
        /// nil when the entry is a preferred device that isn't connected.
        let device: AudioDevice?
        let role: Role
    }

    /// The order keepmic picks inputs in: the preferred mic (listed even when
    /// it's unplugged), then wired headset mics, then the other physical
    /// non-Bluetooth mics by fallback rank. Bluetooth mics never appear.
    static func inputPriority() -> [PriorityEntry] {
        let nonBluetooth = AudioSystem.inputDevices.filter { !$0.isBluetooth }
        var entries: [PriorityEntry] = []

        let preferred = connectedPreferred(among: nonBluetooth)
        let config = Config.load()
        if let preferred {
            entries.append(PriorityEntry(name: preferred.name, device: preferred, role: .preferred))
        } else if let name = config.preferredInput {
            entries.append(PriorityEntry(name: name, device: nil, role: .preferred))
        }

        let physical = nonBluetooth
            .filter { !$0.isVirtual && $0 != preferred }
            .sorted { ($0.fallbackRank, $0.name) < ($1.fallbackRank, $1.name) }
        for device in physical {
            entries.append(PriorityEntry(
                name: device.name, device: device,
                role: device.isWiredHeadsetMic ? .wiredHeadset : .fallback))
        }
        return entries
    }

    /// Starts a pause and hands the mic to the Bluetooth headphones, which is
    /// almost always why someone pauses. Prefers the device used for output,
    /// matched by name since some headsets split input and output into two
    /// devices. Returns the device switched to, if any.
    @discardableResult
    static func pause(minutes: Int) throws -> AudioDevice? {
        try Pause.set(minutes: minutes)
        let bluetoothInputs = AudioSystem.inputDevices.filter { $0.isBluetooth }
        let output = AudioSystem.defaultOutput
        let target = bluetoothInputs.first { $0.id == output?.id || $0.name == output?.name }
            ?? bluetoothInputs.first
        guard let target, AudioSystem.defaultInput?.id != target.id,
              AudioSystem.setDefaultInput(target) else { return nil }
        log("paused for \(minutes) min, default input switched to \(quoted(target.name))")
        return target
    }

    /// The configured preferred device, if it's currently connected.
    /// Matched by stable UID first, then by (apostrophe/case-tolerant) name.
    static func connectedPreferred(among nonBluetooth: [AudioDevice]) -> AudioDevice? {
        let config = Config.load()
        if let uid = config.preferredInputUID,
           let match = nonBluetooth.first(where: { $0.uid == uid }) {
            return match
        }
        if let name = config.preferredInput,
           let match = nonBluetooth.first(where: { deviceNamesMatch($0.name, name) }) {
            return match
        }
        return nil
    }

    private func enforce(trigger: String) {
        pauseRecheck?.cancel()
        pauseRecheck = nil

        if let until = Pause.activeUntil {
            log("\(trigger): paused until \(Self.timeString(until)) — not enforcing")
            // Re-check shortly after the pause expires so the mic gets
            // re-pinned even if no further audio events arrive. Wall-clock
            // deadline so the recheck still fires on time after system sleep.
            let recheck = DispatchWorkItem { self.enforce(trigger: "pause expired") }
            pauseRecheck = recheck
            queue.asyncAfter(wallDeadline: .now() + until.timeIntervalSinceNow + 2, execute: recheck)
            return
        }
        Daemon.enforceOnce(reportSkips: true)
    }

    static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = Calendar.current.isDate(date, inSameDayAs: Date())
            ? "HH:mm:ss"
            : "MMM d, HH:mm"
        return formatter.string(from: date)
    }
}
