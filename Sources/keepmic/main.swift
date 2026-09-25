import Foundation

let help = """
keepmic — stops Bluetooth headphones (AirPods etc.) from hijacking your Mac's mic

When AirPods connect, macOS makes them both the output AND the default input.
The moment any app records from that Bluetooth mic, audio output drops to the
low-quality headset codec. keepmic instantly re-pins the default input to your
Mac's mic whenever that happens, while leaving output on your headphones.

usage: keepmic <command>

  run                 start keepmic in the background (also runs at login)
  quit                stop keepmic and remove it from login
  status              show agent state, current devices, and config
  devices             list input devices
  prefer <name>       always use this mic while it's connected (see `keepmic devices`)
  prefer --clear      go back to the default (built-in mic, guard Bluetooth only)
  pause [minutes]     switch to the Bluetooth mic temporarily (default: 30)
  resume              end a pause and re-pin the mic now
  menubar on          show a menu bar icon with your inputs, outputs, and mic priority
  menubar off         remove the menu bar icon
  daemon              run the guard in the foreground (what the agent runs)
  version             print version
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func commandStatus() {
    print("keepmic \(Version.current)")
    let guardAgent = LaunchAgent.guardAgent
    print("agent:           \(guardAgent.isRunning ? "running" : "not running") (\(guardAgent.label))")
    print("menu bar icon:   \(LaunchAgent.menuBar.isInstalled ? "on" : "off")")

    if let input = AudioSystem.defaultInput {
        print("default input:   \(input.name) (\(input.transportName))")
    } else {
        print("default input:   none")
    }
    if let output = AudioSystem.defaultOutput {
        print("default output:  \(output.name) (\(output.transportName))")
    }

    let config = Config.load()
    print("preferred input: \(config.preferredInput ?? "built-in mic (default)")")

    if let until = Pause.activeUntil {
        print("paused:          yes, until \(Daemon.timeString(until))")
    } else {
        print("paused:          no")
    }
    print("log:             \(Paths.logFile.path)")
}

func commandDevices() {
    let defaultID = AudioSystem.defaultInput?.id
    let devices = AudioSystem.inputDevices
    guard !devices.isEmpty else {
        print("No input devices found.")
        return
    }
    print("Input devices (* = current default):")
    for device in devices {
        let marker = device.id == defaultID ? "*" : " "
        let kind = device.isWiredHeadsetMic ? "wired headset" : device.transportName
        print("  \(marker) \(device.name)  [\(kind)]")
    }
}

func commandPrefer(_ args: [String]) {
    var config = Config.load()
    guard let arg = args.first else {
        print("preferred input: \(config.preferredInput ?? "built-in mic (default)")")
        print("Set one with: keepmic prefer <device name>   (see `keepmic devices`)")
        return
    }
    if arg == "--clear" {
        config.preferredInput = nil
        config.preferredInputUID = nil
        do { try config.save() } catch { fail("Could not save config: \(error)") }
        print("Preferred input cleared — keepmic will pin the built-in mic.")
        return
    }
    let name = args.joined(separator: " ")
    let nonBluetooth = AudioSystem.inputDevices.filter { !$0.isBluetooth }
    if let match = nonBluetooth.first(where: { deviceNamesMatch($0.name, name) }) {
        config.preferredInput = match.name
        config.preferredInputUID = match.uid
        do { try config.save() } catch { fail("Could not save config: \(error)") }
        print("Preferred input set to \(quoted(match.name)) — it will be the default input whenever it's connected.")
    } else if AudioSystem.inputDevices.contains(where: { deviceNamesMatch($0.name, name) }) {
        fail("\(quoted(name)) is a Bluetooth device — keepmic's whole job is keeping input off those.")
    } else {
        config.preferredInput = name
        config.preferredInputUID = nil
        do { try config.save() } catch { fail("Could not save config: \(error)") }
        print("Preferred input set to \(quoted(name)) — not currently connected, so it will be used when available.")
        print("Note: if this is a Bluetooth mic, keepmic will never pin to it.")
    }
}

func commandPause(_ args: [String]) {
    let minutes: Int
    if let arg = args.first {
        guard let parsed = Int(arg), parsed > 0, parsed <= 7 * 24 * 60 else {
            fail("pause expects minutes between 1 and \(7 * 24 * 60) (one week), e.g.: keepmic pause 45")
        }
        minutes = parsed
    } else {
        minutes = 30
    }
    let target: AudioDevice?
    do { target = try Daemon.pause(minutes: minutes) } catch { fail("Could not write pause state: \(error)") }

    let until = Date().addingTimeInterval(TimeInterval(minutes) * 60)
    print("Paused until \(Daemon.timeString(until)). Bluetooth mics are allowed until then.")
    if let target {
        print("Default input switched to \(quoted(target.name)).")
    }
    print("End it early with: keepmic resume")
}

func commandRun(force: Bool) {
    do {
        try LaunchAgent.guardAgent.install(force: force)
        // Restart the menu bar icon too, so it picks up a new binary.
        if LaunchAgent.menuBar.isInstalled {
            try LaunchAgent.menuBar.install(force: force)
        }
    } catch { fail("\(error)") }
    print("keepmic is running in the background (\(LaunchAgent.guardAgent.label))")
    print("  binary:  \(LaunchAgent.binaryPath)")
    print("  log:     \(Paths.logFile.path)")
    print("It starts automatically at login. Stop it with: keepmic quit")
    print("Want a menu bar icon? keepmic menubar on")
    print("(macOS may show a \"Background Items Added\" notification. That's this agent.)")
}

func commandQuit() {
    let menuBarRemoved = LaunchAgent.menuBar.uninstall()
    if LaunchAgent.guardAgent.uninstall() || menuBarRemoved {
        print("keepmic stopped and removed from login. Start it again with: keepmic run")
    } else {
        print("keepmic was not running.")
    }
}

func commandMenuBar(_ args: [String]) {
    switch args.first {
    case "on":
        do { try LaunchAgent.menuBar.install(force: args.contains("--force")) } catch { fail("\(error)") }
        print("Menu bar icon is on. It starts at login. Remove it with: keepmic menubar off")
        if !LaunchAgent.guardAgent.isRunning {
            print("Note: the keepmic guard isn't running. Start it with: keepmic run")
        }
    case "off":
        if LaunchAgent.menuBar.uninstall() {
            print("Menu bar icon removed. The keepmic guard keeps running.")
        } else {
            print("The menu bar icon wasn't on.")
        }
    case nil:
        print("menu bar icon: \(LaunchAgent.menuBar.isInstalled ? "on" : "off")")
        print("Turn it on or off with: keepmic menubar on|off")
    case let other?:
        fail("Unknown option: \(other). Use: keepmic menubar on|off")
    }
}

func commandResume() {
    Pause.clear()
    if Daemon.enforceOnce() {
        print("Resumed — default input re-pinned.")
    } else {
        print("Resumed.")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case nil, "help", "--help", "-h":
    print(help)
case "daemon":
    Daemon().run()
case "run", "install":  // `install` kept as an alias
    if getuid() == 0 {
        fail("Don't run `keepmic run` with sudo — it sets up a per-user agent. Re-run as your normal user.")
    }
    commandRun(force: arguments.contains("--force"))
case "quit", "uninstall":  // `uninstall` kept as an alias
    if getuid() == 0 {
        fail("Don't run `keepmic quit` with sudo — it manages a per-user agent. Re-run as your normal user.")
    }
    commandQuit()
case "menubar":
    commandMenuBar(Array(arguments.dropFirst()))
case "menubar-app":  // what the menu bar agent runs
    MenuBarApp.run()
case "status":
    commandStatus()
case "devices":
    commandDevices()
case "prefer":
    commandPrefer(Array(arguments.dropFirst()))
case "pause":
    commandPause(Array(arguments.dropFirst()))
case "resume":
    commandResume()
case "version", "--version", "-v":
    print("keepmic \(Version.current)")
case let other?:
    fail("Unknown command: \(other)\n\n\(help)")
}
