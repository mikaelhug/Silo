import Foundation
@testable import SiloKit

/// Create a fake `wineserver` socket for `prefix` so `WineServerProbe.isLive(prefix:)` reports it live —
/// mirroring what a running bottle leaves in the per-user temp dir. Creates the prefix dir if needed (so it
/// can be `stat`'d for its dev+inode). Returns a cleanup closure the caller runs to remove the socket dir.
@discardableResult
func makeWineServerSocket(for prefix: URL) throws -> () -> Void {
    try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    guard let dirName = WineServerProbe.serverDirName(for: prefix) else { return {} }
    let root = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp", isDirectory: true)
    let dir = root.appendingPathComponent(".wine-\(getuid())", isDirectory: true)
        .appendingPathComponent(dirName, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: dir.appendingPathComponent("socket").path, contents: Data())
    return { try? FileManager.default.removeItem(at: dir) }
}

/// Remove the fake `wineserver` socket for `prefix` (the inverse of `makeWineServerSocket`) — so a test can
/// flip a bottle from live back to dead.
func removeWineServerSocket(for prefix: URL) {
    guard let dirName = WineServerProbe.serverDirName(for: prefix) else { return }
    let root = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp", isDirectory: true)
    let dir = root.appendingPathComponent(".wine-\(getuid())", isDirectory: true)
        .appendingPathComponent(dirName, isDirectory: true)
    try? FileManager.default.removeItem(at: dir)
}
