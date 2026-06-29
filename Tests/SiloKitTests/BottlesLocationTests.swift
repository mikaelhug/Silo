import Foundation
import Testing
@testable import SiloKit

@Suite("Bottles location + relocation")
struct BottlesLocationTests {

    @Test("bottlesRoot defaults to supportDir; an override redirects only the bottle paths")
    func bottlesRootDerivation() {
        let support = URL(fileURLWithPath: "/sup/Silo")
        let def = AppPaths(supportDir: support)
        #expect(def.bottlesRoot == support)
        #expect(!def.bottlesRelocated)
        #expect(def.steamBottle.path == "/sup/Silo/SteamBottle")
        #expect(def.manualBottlesDir.path == "/sup/Silo/ManualBottles")

        let ext = URL(fileURLWithPath: "/Volumes/Ext/SiloBottles")
        let moved = AppPaths(supportDir: support, bottlesRoot: ext)
        #expect(moved.bottlesRelocated)
        #expect(moved.steamBottle.path == "/Volumes/Ext/SiloBottles/SteamBottle")
        let id = UUID()
        #expect(moved.manualBottle(id).path == "/Volumes/Ext/SiloBottles/ManualBottles/\(id.uuidString)")
        // App state (config/logs/runtimes) stays under supportDir regardless of where bottles live.
        #expect(moved.configFile.path == "/sup/Silo/config.json")
        #expect(moved.runtimesDir.path == "/sup/Silo/Runtimes")
    }

    @Test("BottlesLocation persists + clears the override, readable synchronously")
    func persistence() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let support = tmp.url.appendingPathComponent("Silo")
        #expect(BottlesLocation.read(supportDir: support) == nil)                 // none set → default

        let root = URL(fileURLWithPath: "/Volumes/Ext/SiloBottles")
        BottlesLocation.write(root, supportDir: support)
        #expect(BottlesLocation.read(supportDir: support)?.path == "/Volumes/Ext/SiloBottles")
        // A freshly-built AppPaths.* would pick this up via standard()'s read; emulate the wiring:
        #expect(AppPaths(supportDir: support, bottlesRoot: BottlesLocation.read(supportDir: support))
            .steamBottle.path == "/Volumes/Ext/SiloBottles/SteamBottle")

        BottlesLocation.write(nil, supportDir: support)
        #expect(BottlesLocation.read(supportDir: support) == nil)                 // cleared
    }

    @Test("relocator moves existing bottle dirs (move, not copy) and skips absent ones")
    func relocatorMoves() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let old = try tmp.makeDir("old")
        let new = tmp.url.appendingPathComponent("new")     // created by the relocator
        try tmp.write("old/SteamBottle/drive_c/marker", "x")  // only SteamBottle present

        try await BottleRelocator().move(AppPaths.bottleDirNames, from: old, to: new)

        #expect(FileManager.default.fileExists(
            atPath: new.appendingPathComponent("SteamBottle/drive_c/marker").path))
        #expect(!FileManager.default.fileExists(atPath: old.appendingPathComponent("SteamBottle").path)) // moved
        #expect(!FileManager.default.fileExists(atPath: new.appendingPathComponent("ManualBottles").path)) // skipped
    }

    @Test("relocator cross-volume copy preserves files + symlinks and reports progress to 100%")
    func relocatorCopyProgress() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let old = try tmp.makeDir("old")
        let new = tmp.url.appendingPathComponent("new")
        try tmp.write("old/SteamBottle/drive_c/a.txt", "hello")
        try tmp.write("old/SteamBottle/drive_c/sub/b.bin", "world!!")
        // A symlink inside the bottle (Wine prefixes are full of these — must survive, not be dereferenced).
        let dosdevices = try tmp.makeDir("old/SteamBottle/dosdevices")
        try FileManager.default.createSymbolicLink(
            atPath: dosdevices.appendingPathComponent("z:").path, withDestinationPath: "/")

        let last = LockedDouble()
        // forceCopy → exercise the cross-volume copy path even though tmp is one volume.
        try await BottleRelocator().move(["SteamBottle"], from: old, to: new, forceCopy: true,
                                         onProgress: { last.set($0) })

        #expect(try String(contentsOf: new.appendingPathComponent("SteamBottle/drive_c/a.txt"), encoding: .utf8) == "hello")
        #expect(try String(contentsOf: new.appendingPathComponent("SteamBottle/drive_c/sub/b.bin"), encoding: .utf8) == "world!!")
        let z = new.appendingPathComponent("SteamBottle/dosdevices/z:")
        #expect((try z.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true)   // link preserved
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: z.path) == "/")
        #expect(!FileManager.default.fileExists(atPath: old.appendingPathComponent("SteamBottle").path)) // source removed
        #expect(last.value == 1.0)                                                              // reached 100%
    }

    @Test("relocator refuses the same location and an occupied destination (source untouched)")
    func relocatorRefuses() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let old = try tmp.makeDir("old")
        try tmp.write("old/SteamBottle/x", "1")

        await #expect(throws: BottleRelocator.RelocateError.sameLocation) {
            try await BottleRelocator().move(["SteamBottle"], from: old, to: old)
        }

        let new = try tmp.makeDir("new")
        try tmp.write("new/SteamBottle/y", "2")              // dest already occupied
        await #expect(throws: BottleRelocator.RelocateError.self) {
            try await BottleRelocator().move(["SteamBottle"], from: old, to: new)
        }
        #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent("SteamBottle/x").path)) // intact
    }
}

/// Lock-guarded Double for capturing the latest value from a `@Sendable` progress callback in tests.
private final class LockedDouble: @unchecked Sendable {   // safe: every access is lock-guarded
    private let lock = NSLock()
    private var stored = 0.0
    var value: Double { lock.withLock { stored } }
    func set(_ v: Double) { lock.withLock { stored = v } }
}
