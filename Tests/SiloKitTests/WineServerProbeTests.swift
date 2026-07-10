import Foundation
import Testing
@testable import SiloKit

@Suite("WineServerProbe")
struct WineServerProbeTests {

    @Test("serverDirName matches wine's hex dev-inode naming for a real dir")
    func serverDirNameFormat() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let name = try #require(WineServerProbe.serverDirName(for: tmp.url))
        #expect(name.hasPrefix("server-"))
        // Independently stat the dir and reconstruct the expected name.
        var st = stat()
        #expect(stat(tmp.url.path, &st) == 0)
        let expected = "server-\(String(UInt64(bitPattern: Int64(st.st_dev)), radix: 16))"
            + "-\(String(st.st_ino, radix: 16))"
        #expect(name == expected)
    }

    @Test("serverDirName is nil for a nonexistent prefix (a not-yet-created bottle is never live)")
    func serverDirNameNilForMissing() {
        #expect(WineServerProbe.serverDirName(
            for: URL(fileURLWithPath: "/no/such/prefix-\(UUID().uuidString)")) == nil)
    }

    @Test("isLive is true only while the wineserver socket exists")
    func isLiveTracksSocket() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefix = tmp.url.appendingPathComponent("SteamBottle")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        #expect(!WineServerProbe.isLive(prefix: prefix))          // no server yet
        let remove = try makeWineServerSocket(for: prefix)
        #expect(WineServerProbe.isLive(prefix: prefix))           // socket present → live
        remove()
        #expect(!WineServerProbe.isLive(prefix: prefix))          // socket gone → not live
    }

    @Test("isAnyBottleLive spots a live manual bottle, and reports false when all are quiet")
    func anyBottleLive() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        #expect(!WineServerProbe.isAnyBottleLive(paths: paths))
        let remove = try makeWineServerSocket(for: paths.manualBottle(UUID()))
        defer { remove() }
        #expect(WineServerProbe.isAnyBottleLive(paths: paths))
    }
}
