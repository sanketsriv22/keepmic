import Foundation

enum Version {
    static let current = "0.1.0"
}

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static let stateDir = home.appendingPathComponent(
        "Library/Application Support/keepmic", isDirectory: true)
    static let configFile = stateDir.appendingPathComponent("config.json")
    static let pauseFile = stateDir.appendingPathComponent("paused-until")

    static let logFile = home.appendingPathComponent("Library/Logs/keepmic.log")
    static let launchAgentPlist = home.appendingPathComponent(
        "Library/LaunchAgents/\(LaunchAgent.label).plist")
}

struct Config: Codable {
    /// Name of the input device to pin (as shown by `keepmic devices`).
    /// When unset, keepmic prefers the built-in mic, then any physical
    /// non-Bluetooth input.
    var preferredInput: String?
    /// Stable device UID captured when the preferred device was connected at
    /// `prefer` time — disambiguates devices that share a display name.
    var preferredInputUID: String?

    static func load() -> Config {
        guard let data = try? Data(contentsOf: Paths.configFile),
              let config = try? JSONDecoder().decode(Config.self, from: data) else {
            return Config()
        }
        return config
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Paths.stateDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Paths.configFile, options: .atomic)
    }
}

enum Pause {
    /// Returns the pause expiry if a pause is currently active, else nil.
    static var activeUntil: Date? {
        guard let text = try? String(contentsOf: Paths.pauseFile, encoding: .utf8),
              let epoch = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        let until = Date(timeIntervalSince1970: epoch)
        return until > Date() ? until : nil
    }

    static func set(minutes: Int) throws {
        try FileManager.default.createDirectory(at: Paths.stateDir, withIntermediateDirectories: true)
        let until = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        try String(until.timeIntervalSince1970)
            .write(to: Paths.pauseFile, atomically: true, encoding: .utf8)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: Paths.pauseFile)
    }
}

private let logTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
}()

func log(_ message: String) {
    print("\(logTimestampFormatter.string(from: Date())) \(message)")
    fflush(stdout)
}

func quoted(_ name: String) -> String { "\"\(name)\"" }
