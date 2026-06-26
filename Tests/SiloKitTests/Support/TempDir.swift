import Foundation

/// A scratch directory for filesystem tests, removed on `deinit`.
final class TempDir {
    let url: URL

    init(_ name: String = "silo-test") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Create a subdirectory (with intermediates) and return its URL.
    @discardableResult
    func makeDir(_ relativePath: String) throws -> URL {
        let dir = url.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write a UTF-8 file (creating intermediate directories) and return its URL.
    @discardableResult
    func write(_ relativePath: String, _ contents: String) throws -> URL {
        let fileURL = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    func cleanup() { try? FileManager.default.removeItem(at: url) }
    deinit { cleanup() }
}
