import Darwin
import Foundation

enum LaunchAgent {
    static let label = "com.keepmic.agent"

    /// Absolute path of the currently running binary. The launchd plist points
    /// here, so install from the binary's final location. Symlinks are kept
    /// as-is so a Homebrew-style symlink stays stable across upgrades.
    static var binaryPath: String {
        if let url = Bundle.main.executableURL {
            return url.standardizedFileURL.path
        }
        return URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    }

    private static var serviceTarget: String { "gui/\(getuid())/\(label)" }
    private static var domainTarget: String { "gui/\(getuid())" }

    static func install(force: Bool = false) throws {
        let binary = binaryPath

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
                  keepmic install

                (Or re-run with `keepmic install --force` if you really want this path.)
                """)
        }

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(xmlEscaped(binary))</string>
                <string>run</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <dict>
                <key>PathState</key>
                <dict>
                    <key>\(xmlEscaped(binary))</key>
                    <true/>
                </dict>
            </dict>
            <key>ProcessType</key>
            <string>Background</string>
            <key>StandardOutPath</key>
            <string>\(xmlEscaped(Paths.logFile.path))</string>
            <key>StandardErrorPath</key>
            <string>\(xmlEscaped(Paths.logFile.path))</string>
        </dict>
        </plist>
        """

        let plistURL = Paths.launchAgentPlist
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Unload any previous version, then wait for launchd to let go of the
        // service before bootstrapping again — back-to-back bootout/bootstrap
        // can fail intermittently otherwise.
        _ = launchctl(["bootout", serviceTarget])
        for _ in 0..<10 where launchctl(["print", serviceTarget]).status == 0 {
            usleep(100_000)
        }

        try plist.write(to: plistURL, atomically: true, encoding: .utf8)

        var result = launchctl(["bootstrap", domainTarget, plistURL.path])
        var attempts = 1
        while result.status != 0 && attempts < 4 {
            usleep(300_000)
            result = launchctl(["bootstrap", domainTarget, plistURL.path])
            attempts += 1
        }
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: plistURL)
            throw KeepmicError(
                "launchctl bootstrap failed (\(result.status)): \(result.output)\n"
                + "Try manually: launchctl bootstrap \(domainTarget) \(plistURL.path)")
        }

        print("keepmic agent installed and running (\(label))")
        print("  binary:  \(binary)")
        print("  log:     \(Paths.logFile.path)")
        print("It starts automatically at login. Remove with: keepmic uninstall")
        print("(macOS may show a \"Background Items Added\" notification — that's this agent.)")
    }

    static func uninstall() {
        let result = launchctl(["bootout", serviceTarget])
        let plistExisted = FileManager.default.fileExists(atPath: Paths.launchAgentPlist.path)
        try? FileManager.default.removeItem(at: Paths.launchAgentPlist)

        if result.status == 0 || plistExisted {
            print("keepmic agent stopped and removed.")
        } else {
            print("keepmic agent was not installed.")
        }
    }

    static var isRunning: Bool {
        launchctl(["print", serviceTarget]).status == 0
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
