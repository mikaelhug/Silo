import Foundation
import CryptoKit

/// Streaming SHA-256 of a file on disk. Shared by the runtime-install and app-updater integrity
/// checks so both compute the digest the same way (memory-safe for ~250 MB archives — reads in 1 MB
/// chunks rather than loading the whole file).
enum FileDigest {
    /// Lower-case hex SHA-256 of the file at `url`. Throws if the file can't be opened/read, so a
    /// caller comparing against an expected digest fails *closed* rather than matching against "".
    static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
