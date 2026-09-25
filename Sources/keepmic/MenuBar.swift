import AppKit
import CoreAudio

/// Optional menu bar icon (`keepmic menubar on`). Runs as its own launchd
/// agent, separate from the guard, so the guard stays UI-free and a menu bar
/// problem can never stop the mic from being pinned.
enum MenuBarApp {
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)  // no Dock icon
        let controller = MenuBarController()
        controller.start()
        withExtendedLifetime(controller) { app.run() }
        exit(0)
    }
}

final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var refreshTimer: Timer?

    func start() {
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        for selector in [
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDevices,
        ] {
            AudioSystem.addListener(selector, queue: .main) { [weak self] in self?.refreshIcon() }
        }
        // Pause state lives in a file the CLI can change, and pauses expire
        // on their own, so re-check now and then. Cheap: one file read.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.refreshIcon()
        }
        refreshIcon()
    }

    // MARK: Icon

    private func refreshIcon() {
        let symbol: String
        let state: String
        if !LaunchAgent.guardAgent.isRunning {
            symbol = "mic.slash"
            state = "keepmic is not running"
        } else if let until = Pause.activeUntil {
            symbol = "pause.circle"
            state = "Paused until \(Daemon.timeString(until))"
        } else {
            symbol = "mic.fill"
            state = "Guarding"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "keepmic")
        image?.isTemplate = true
        statusItem.button?.image = image

        let input = AudioSystem.defaultInput?.name ?? "none"
        let output = AudioSystem.defaultOutput?.name ?? "none"
        statusItem.button?.toolTip = "\(state)\nInput: \(input)\nOutput: \(output)"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let guardRunning = LaunchAgent.guardAgent.isRunning
        let pausedUntil = Pause.activeUntil

        let status: String
        if !guardRunning {
            status = "not running"
        } else if let pausedUntil {
            status = "paused until \(Daemon.timeString(pausedUntil))"
        } else {
            status = "guarding"
        }
        menu.addItem(header("keepmic \(Version.current) · \(status)"))
        menu.addItem(.separator())

        addOutputs(to: menu)
        menu.addItem(.separator())
        addInputs(to: menu)
        menu.addItem(.separator())

        if !guardRunning {
            menu.addItem(action("Start keepmic", #selector(startGuard)))
        } else if pausedUntil != nil {
            menu.addItem(action("Resume guarding", #selector(resume)))
        } else {
            let pauseItem = NSMenuItem(title: "Pause (use Bluetooth mic)", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for minutes in [15, 30, 60, 120] {
                let item = action(minutes < 60 ? "\(minutes) minutes" : "\(minutes / 60) hour\(minutes > 60 ? "s" : "")",
                                  #selector(pause(_:)))
                item.tag = minutes
                submenu.addItem(item)
            }
            pauseItem.submenu = submenu
            menu.addItem(pauseItem)
        }
        if Config.load().preferredInput != nil {
            menu.addItem(action("Clear preferred mic", #selector(clearPreferred)))
        }
        menu.addItem(action("Open log", #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(action("Hide menu bar icon", #selector(hideIcon)))
    }

    private func addOutputs(to menu: NSMenu) {
        menu.addItem(header("Output"))
        let current = AudioSystem.defaultOutput
        for device in AudioSystem.outputDevices {
            let item = action("", #selector(selectOutput(_:)))
            item.attributedTitle = row(device.name, detail: device.transportName)
            item.state = device == current ? .on : .off
            item.representedObject = device.id
            menu.addItem(item)
        }
    }

    private func addInputs(to menu: NSMenu) {
        menu.addItem(header("Input priority"))
        let current = AudioSystem.defaultInput
        let entries = Daemon.inputPriority()

        for (index, entry) in entries.enumerated() {
            var detail: String
            switch entry.role {
            case .preferred: detail = "preferred"
            case .wiredHeadset: detail = "wired headset"
            case .fallback: detail = entry.device?.transportName ?? ""
            }
            if entry.device == nil { detail += ", not connected" }

            let item = action("", #selector(preferInput(_:)))
            item.attributedTitle = row("\(index + 1). \(entry.name)", detail: detail)
            item.state = entry.device != nil && entry.device == current ? .on : .off
            if let device = entry.device, entry.role != .preferred {
                item.representedObject = device.id
                item.toolTip = "Make \(entry.name) your preferred mic"
            } else {
                item.isEnabled = entry.device != nil
                item.action = nil
            }
            menu.addItem(item)
        }

        // Bluetooth mics are never picked; show them so the list is complete,
        // and so it's obvious when one holds the input during a pause.
        for device in AudioSystem.inputDevices where device.isBluetooth {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.attributedTitle = row(device.name, detail: "bluetooth, never used")
            item.state = device == current ? .on : .off
            item.isEnabled = false
            menu.addItem(item)
        }

        // Anything else holding the input (a virtual device picked by hand,
        // say) still gets shown as the current input.
        let listed = entries.compactMap(\.device) + AudioSystem.inputDevices.filter(\.isBluetooth)
        if let current, !listed.contains(current) {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.attributedTitle = row(current.name, detail: "\(current.transportName), set by hand")
            item.state = .on
            item.isEnabled = false
            menu.addItem(item)
        }
    }

    // MARK: Actions

    @objc private func selectOutput(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? AudioDeviceID else { return }
        AudioSystem.setDefaultOutput(AudioDevice(id: id))
    }

    @objc private func preferInput(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? AudioDeviceID else { return }
        let device = AudioDevice(id: id)
        var config = Config.load()
        config.preferredInput = device.name
        config.preferredInputUID = device.uid
        do { try config.save() } catch {
            log("menu bar: could not save preferred mic: \(error)")
            return
        }
        log("menu bar: preferred input set to \(quoted(device.name))")
        if Pause.activeUntil == nil { Daemon.enforceOnce() }
    }

    @objc private func clearPreferred() {
        var config = Config.load()
        config.preferredInput = nil
        config.preferredInputUID = nil
        do { try config.save() } catch {
            log("menu bar: could not clear preferred mic: \(error)")
            return
        }
        log("menu bar: preferred input cleared")
        if Pause.activeUntil == nil { Daemon.enforceOnce() }
    }

    @objc private func pause(_ sender: NSMenuItem) {
        do { try Daemon.pause(minutes: sender.tag) } catch {
            log("menu bar: could not pause: \(error)")
        }
        refreshIcon()
    }

    @objc private func resume() {
        Pause.clear()
        Daemon.enforceOnce()
        refreshIcon()
    }

    @objc private func startGuard() {
        do { try LaunchAgent.guardAgent.install() } catch {
            log("menu bar: could not start keepmic: \(error)")
        }
        refreshIcon()
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Paths.logFile)
    }

    @objc private func hideIcon() {
        log("menu bar: icon hidden (turn it back on with: keepmic menubar on)")
        LaunchAgent.menuBar.uninstall()
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func row(_ name: String, detail: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
        ])
        guard !detail.isEmpty else { return text }
        text.append(NSAttributedString(string: "  \(detail)", attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return text
    }
}
