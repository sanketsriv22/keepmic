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
    @discardableResult
    static func enforceOnce(reportSkips: Bool = false) -> Bool {
        guard let current = AudioSystem.defaultInput else { return false }
        guard current.isBluetooth else { return false }
        guard let target = pickFallback() else {
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

    /// Picks the device to pin input to: the configured preferred device if
    /// present, else the built-in mic, else the best-ranked physical input.
    /// Virtual/aggregate devices (loopbacks like BlackHole) are never chosen
    /// automatically — only when explicitly set via `keepmic prefer`.
    static func pickFallback() -> AudioDevice? {
        let nonBluetooth = AudioSystem.inputDevices.filter { !$0.isBluetooth }
        guard !nonBluetooth.isEmpty else { return nil }

        let config = Config.load()
        if config.preferredInput != nil || config.preferredInputUID != nil {
            if let uid = config.preferredInputUID,
               let match = nonBluetooth.first(where: { $0.uid == uid }) {
                return match
            }
            if let name = config.preferredInput,
               let match = nonBluetooth.first(where: { deviceNamesMatch($0.name, name) }) {
                return match
            }
            log("preferred input \(quoted(config.preferredInput ?? "?")) is not connected — falling back")
        }

        let physical = nonBluetooth.filter { !$0.isVirtual }
        return physical.min { ($0.fallbackRank, $0.name) < ($1.fallbackRank, $1.name) }
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
