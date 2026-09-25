import Darwin
import Foundation

/// A per-user launchd agent that runs this binary with some arguments.
/// keepmic has two: the guard (`daemon`) and the optional menu bar icon.
struct LaunchAgent {
    let label: String
    let arguments: [String]
    /// launchd ProcessType. The guard is "Background"; the menu bar app is
    /// "Interactive" so macOS doesn't throttle it while you're using the menu.
    let processType: String

    static let guardAgent = LaunchAgent(label: "com.keepmic.agent", arguments: ["daemon"], processType: "Background")
    static let menuBar = LaunchAgent(label: "com.keepmic.menubar", arguments: ["menubar-app"], processType: "Interactive")

    /// Absolute path of the currently running binary. The launchd plist points
    /// here, so install from the binary's final location. Symlinks are kept
    /// as-is so a Homebrew-style symlink stays stable across upgrades.
    static var binaryPath: String {
        if let url = Bundle.main.executableURL {
            return url.standardizedFileURL.path
        }
        return URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    }

    var plistURL: URL {
        Paths.home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private var serviceTarget: String { "gui/\(getuid())/\(label)" }
    private var domainTarget: String { "gui/\(getuid())" }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    var isRunning: Bool {
        Self.launchctl(["print", serviceTarget]).status == 0
    }

    func install(force: Bool = false) throws {
        let binary = Self.binaryPath

        // A plist pointing into a build directory turns into a respawn loop of
        // a missing binary as soon as the repo is cleaned or deleted.
        let ephemeralMarkers = ["/.build/", "/DerivedData/"]
        if !force, ephemeralMarkers.contains(where: { binary.contains($0) }) {
            throw KeepmicError("""
                This binary lives in a temporary build directory:
                  \(binary)
                Installing the agent from here would break as soon as the build folder
                is cleaned or the repo is moved. Install the binary somewhere stable first:

                  make install      # from the repo root
                  keepmic run

                (Or re-run with `--force` if you really want this path.)
                """)
        }

        let programArguments = ([binary] + arguments)
            .map { "        <string>\(Self.xmlEscaped($0))</string>" }
            .joined(separator: "\n")

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
        \(programArguments)
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <dict>
                <key>PathState</key>
                <dict>
                    <key>\(Self.xmlEscaped(binary))</key>
                    <true/>
                </dict>
            </dict>
            <key>ProcessType</key>
            <string>\(processType)</string>
            <key>StandardOutPath</key>
            <string>\(Self.xmlEscaped(Paths.logFile.path))</string>
            <key>StandardErrorPath</key>
            <string>\(Self.xmlEscaped(Paths.logFile.path))</string>
        </dict>
        </plist>
        """

        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Unload any previous version, then wait for launchd to let go of the
        // service before bootstrapping again. Back-to-back bootout/bootstrap
        // can fail intermittently otherwise.
        _ = Self.launchctl(["bootout", serviceTarget])
        for _ in 0..<10 where Self.launchctl(["print", serviceTarget]).status == 0 {
            usleep(100_000)
        }

        try plist.write(to: plistURL, atomically: true, encoding: .utf8)

        var result = Self.launchctl(["bootstrap", domainTarget, plistURL.path])
        var attempts = 1
        while result.status != 0 && attempts < 4 {
            usleep(300_000)
            result = Self.launchctl(["bootstrap", domainTarget, plistURL.path])
            attempts += 1
        }
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: plistURL)
            throw KeepmicError(
                "launchctl bootstrap failed (\(result.status)): \(result.output)\n"
                + "Try manually: launchctl bootstrap \(domainTarget) \(plistURL.path)")
        }
    }

    /// Removes the plist first, then unloads the service, so an agent can
    /// uninstall itself (bootout kills the calling process when it's the
    /// service being booted out). Returns whether anything was there.
    @discardableResult
    func uninstall() -> Bool {
        let plistExisted = isInstalled
        try? FileManager.default.removeItem(at: plistURL)
        let result = Self.launchctl(["bootout", serviceTarget])
        return result.status == 0 || plistExisted
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func launchctl(_ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (1, "failed to run launchctl: \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

struct KeepmicError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
