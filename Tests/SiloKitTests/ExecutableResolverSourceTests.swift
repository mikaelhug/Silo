import Foundation
import Testing
@testable import SiloKit

/// REGRESSION. Every free Source-engine title tested launched the WRONG program, because `firstExecutable`
/// picked the largest `.exe` anywhere in the tree: a game's launcher is routinely a small stub at the install
/// root, while the biggest binaries are engine tooling in `bin/`. The layouts below are the REAL ones from
/// this machine's Steam library (names, sizes and depths as observed), not shapes invented to match the fix.
@Suite("Executable resolution — real game layouts")
struct ExecutableResolverSourceTests {

    /// Build a temp install tree from `(relativePath, size)` pairs and resolve it.
    private func resolve(_ dir: String, _ files: [(String, Int)], in tmp: TempDir) throws -> String? {
        let root = tmp.url.appendingPathComponent(dir)
        for (rel, size) in files {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(count: size).write(to: url)
        }
        return ExecutableResolver.firstExecutable(in: root)?.lastPathComponent
    }

    /// Source SDK 2013: `hl2.exe` is a small launcher at the root; `bin/` holds multi-MB engine tools. The
    /// old "largest exe" rule launched `bin/elementviewer.exe` (3.2 MB, a model viewer) — it exits at once,
    /// so the game simply never appeared.
    @Test("a Source game resolves to its root launcher, not the biggest tool in bin/")
    func sourceGameResolvesToLauncher() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        for dir in ["Transmissions Element 120", "Double Action"] {
            let exe = try resolve(dir, [
                ("hl2.exe", 250_000),
                ("bin/elementviewer.exe", 3_194_368),
                ("bin/qc_eyes.exe", 2_911_232),
                ("bin/studiomdl.exe", 1_802_240),
                ("bin/bspzip.exe", 500_000),
            ], in: tmp)
            #expect(exe == "hl2.exe", "\(dir) must launch its root hl2.exe")
        }
    }

    /// Alien Swarm needs BOTH halves of the fix: depth alone leaves `srcds.exe` (Source's dedicated SERVER,
    /// 86 KB) beating the game's own `swarm.exe` (78 KB) at the root, and size alone picks
    /// `bin/addoninstaller.exe`.
    @Test("Alien Swarm resolves to the game, not the dedicated server or the addon installer")
    func alienSwarmResolvesToGame() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try resolve("Alien Swarm", [
            ("swarm.exe", 77_824),
            ("srcds.exe", 86_016),
            ("bin/addoninstaller.exe", 131_072),
        ], in: tmp)
        #expect(exe == "swarm.exe")
    }

    /// The other direction — the games that already worked must not regress. Split Fiction keeps its real
    /// executable THREE levels down, so "shallowest wins" must be applied to the surviving pool rather than
    /// assuming the game sits at the root; Bloons TD 6 ships a crash handler at the root that is more than
    /// twice the size of the game.
    @Test("nested and crash-handler layouts still resolve correctly")
    func knownGoodLayoutsAreUnchanged() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let split = try resolve("Split Fiction", [
            ("Split/Binaries/Win64/SplitFiction.exe", 279_069_712),
            ("Engine/Extras/Redist/en-us/UEPrereqSetup_x64.exe", 50_521_128),
        ], in: tmp)
        #expect(split == "SplitFiction.exe")

        let bloons = try resolve("BloonsTD6", [
            ("BloonsTD6.exe", 672_256),
            ("UnityCrashHandler64.exe", 1_531_824),
            ("Cleaner/Cleaner-BTD6.exe", 26_112),
        ], in: tmp)
        #expect(bloons == "BloonsTD6.exe")
    }
}
