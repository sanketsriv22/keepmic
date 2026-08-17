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
    /// Two rules, in order:
    /// 1. If the preferred device (`keepmic prefer`) is connected, it must be
    ///    the default input — a preferred mic always wins while present.
    /// 2. Otherwise, if a Bluetooth device holds the default input, pin it
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
