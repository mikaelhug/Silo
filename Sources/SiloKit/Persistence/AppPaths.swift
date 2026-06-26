import Foundation

/// Canonical filesystem locations under `~/Library/Application Support/Silo`.
public struct AppPaths: Sendable, Hashable {
    public let supportDir: URL

    public init(supportDir: URL) {
        self.supportDir = supportDir
    }

    /// The standard location under the user's Application Support directory.
    public static func standard(fileManager: FileManager = .default) -> AppPaths {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Silo", isDirectory: true)
        return AppPaths(supportDir: base)
    }

    /// Default location for the Master Steam bottle (one-click install target).
    public var masterBottleDefault: URL { supportDir.appendingPathComponent("MasterBottle", isDirectory: true) }
    public var prefixesDir: URL { supportDir.appendingPathComponent("Prefixes", isDirectory: true) }
    public var runtimesDir: URL { supportDir.appendingPathComponent("Runtimes", isDirectory: true) }
    public var logsDir: URL { supportDir.appendingPathComponent("Logs", isDirectory: true) }
    public var configFile: URL { supportDir.appendingPathComponent("config.json") }

    /// Isolated Wine prefix root for a game.
    public func prefix(forAppID appID: Int) -> URL {
        prefixesDir.appendingPathComponent("\(appID)", isDirectory: true)
    }

    /// Per-game launch log file.
    public func log(forAppID appID: Int) -> URL {
        logsDir.appendingPathComponent("\(appID).log")
    }
}
