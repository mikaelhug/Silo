import Foundation

/// Manages per-game launch logs under the Logs directory.
public actor GameLogStore {
    private let paths: AppPaths
    private let fileManager: FileManager

    public init(paths: AppPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public nonisolated func logURL(forAppID appID: Int) -> URL {
        paths.log(forAppID: appID)
    }

    /// Create the logs dir and truncate the log for a fresh launch session; returns the URL.
    @discardableResult
    public func prepare(appID: Int) throws -> URL {
        try fileManager.createDirectory(at: paths.logsDir, withIntermediateDirectories: true)
        let url = paths.log(forAppID: appID)
        try Data().write(to: url)
        return url
    }

    /// Current log contents (for the log viewer).
    public func read(appID: Int) -> String {
        (try? String(contentsOf: paths.log(forAppID: appID), encoding: .utf8)) ?? ""
    }

    public func clear(appID: Int) throws {
        try Data().write(to: paths.log(forAppID: appID))
    }
}
