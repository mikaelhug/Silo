import Foundation
import Testing
@testable import SiloKit

@Suite("BottleShortcuts discovery")
struct BottleShortcutsTests {
    /// A fake bottle: the real GravityMark shortcut in the Start Menu, plus (optionally) its target exe on
    /// disk so the existence check passes.
    private func makeBottle(withTarget: Bool) throws -> TempDir {
        let tmp = try TempDir("bottle")
        let sm = try tmp.makeDir(
            "drive_c/users/crossover/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/GravityMark")
        try FileManager.default.copyItem(
            at: FixtureLoader.url("GravityMark.lnk"),
            to: sm.appendingPathComponent("GravityMark 1.89.lnk"))
        if withTarget {
            let bin = try tmp.makeDir("drive_c/Program Files/GravityMark/bin")
            FileManager.default.createFile(atPath: bin.appendingPathComponent("Browser.exe").path, contents: Data())
        }
        return tmp
    }

    @Test("Finds the installer shortcut and resolves target + args + working dir to host paths")
    func findsShortcut() throws {
        let tmp = try makeBottle(withTarget: true)
        let found = BottleShortcuts.discover(inBottle: tmp.url)
        #expect(found.count == 1)
        let s = try #require(found.first)
        #expect(s.name == "GravityMark GPU Benchmark")
        #expect(s.executable.path
                == tmp.url.appendingPathComponent("drive_c/Program Files/GravityMark/bin/Browser.exe").path)
        #expect(s.arguments == ["-root", "browser/", "../browser.zip"])
        #expect(s.workingDirectory?.path
                == tmp.url.appendingPathComponent("drive_c/Program Files/GravityMark/bin").path)
    }

    @Test("A shortcut whose target isn't installed is skipped (fail closed)")
    func skipsMissingTarget() throws {
        let tmp = try makeBottle(withTarget: false)
        #expect(BottleShortcuts.discover(inBottle: tmp.url).isEmpty)
    }

    @Test("Windows C: path maps under drive_c; other drives / junk are unmapped")
    func mapsPaths() {
        let prefix = URL(fileURLWithPath: "/b")
        #expect(BottleShortcuts.hostURL(forWindowsPath: #"C:\Program Files\X\y.exe"#, prefix: prefix)?.path
                == "/b/drive_c/Program Files/X/y.exe")
        #expect(BottleShortcuts.hostURL(forWindowsPath: #"c:\a\b"#, prefix: prefix)?.path == "/b/drive_c/a/b")
        #expect(BottleShortcuts.hostURL(forWindowsPath: #"Z:\net\x"#, prefix: prefix) == nil)
        #expect(BottleShortcuts.hostURL(forWindowsPath: "", prefix: prefix) == nil)
    }

    @Test("Uninstaller entries (label, msiexec, Inno unins*) are filtered")
    func filtersUninstallers() {
        let game = URL(fileURLWithPath: "/b/drive_c/App/foo.exe")
        #expect(BottleShortcuts.isUninstaller(name: "Uninstall GravityMark", target: game))
        #expect(BottleShortcuts.isUninstaller(name: nil, target: URL(fileURLWithPath: "/w/msiexec.exe")))
        #expect(BottleShortcuts.isUninstaller(name: nil, target: URL(fileURLWithPath: "/app/unins000.exe")))
        #expect(!BottleShortcuts.isUninstaller(name: "GravityMark", target: game))
    }
}
