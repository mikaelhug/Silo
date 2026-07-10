import Foundation
import Testing
@testable import SiloKit

@Suite("DockAppBundle")
struct DockAppBundleTests {

    private let loader = URL(fileURLWithPath: "/rt/bin/wine64")

    @Test("Info.plist names the Dock tile via CFBundleName and carries no icon / LSUIElement")
    func infoPlist() {
        let plist = DockAppBundle(displayName: "Steam", folderName: "Steam", wineLoader: loader).infoPlist()
        #expect(plist.contains("<key>CFBundleName</key><string>Steam</string>"))
        #expect(plist.contains("<key>CFBundleDisplayName</key><string>Steam</string>"))
        #expect(plist.contains("<key>CFBundleExecutable</key><string>Steam</string>"))
        #expect(plist.contains("<key>CFBundleIdentifier</key><string>com.silo.dock.Steam</string>"))
        // The live icon comes from winemac.drv at runtime — no bundle icon.
        #expect(!plist.contains("CFBundleIconFile"))
        // We WANT a Dock tile, so it must not be an agent.
        #expect(!plist.contains("LSUIElement"))
    }

    @Test("executable name folds path-hostile characters but keeps spaces")
    func executableName() {
        #expect(DockAppBundle(displayName: "Overcooked 2", folderName: "app-448510", wineLoader: loader)
            .executableName == "Overcooked 2")
        #expect(DockAppBundle(displayName: "DOOM/Eternal: 2", folderName: "x", wineLoader: loader)
            .executableName == "DOOM-Eternal- 2")
        // An empty/whitespace name falls back to a placeholder rather than an unnamed executable.
        #expect(DockAppBundle(displayName: "   ", folderName: "x", wineLoader: loader)
            .executableName == "Game")
    }

    @Test("folderName drives the .app dir independently of the display name; identifier is slug-safe")
    func folderVsDisplay() {
        let plist = DockAppBundle(displayName: "Overcooked 2", folderName: "app-448510", wineLoader: loader)
            .infoPlist()
        #expect(plist.contains("<key>CFBundleName</key><string>Overcooked 2</string>"))
        #expect(plist.contains("<key>CFBundleIdentifier</key><string>com.silo.dock.app-448510</string>"))
    }

    @Test("write creates <folderName>.app whose MacOS/<exe> is a symlink to the loader")
    func writeSymlink() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        // A real loader file to point the symlink at (destination need not exist, but assert path anyway).
        let rt = tmp.url.appendingPathComponent("rt/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: rt, withIntermediateDirectories: true)
        let realLoader = rt.appendingPathComponent("wine64")
        FileManager.default.createFile(atPath: realLoader.path, contents: Data("loader".utf8))

        let bundle = DockAppBundle(displayName: "Steam", folderName: "Steam", wineLoader: realLoader)
        let exe = try bundle.write(into: tmp.url)
        let fm = FileManager.default

        #expect(exe.path.hasSuffix("Steam.app/Contents/MacOS/Steam"))
        #expect(fm.fileExists(atPath: tmp.url.appendingPathComponent("Steam.app/Contents/Info.plist").path))
        // It's a SYMLINK (not a copy / script) pointing at the real loader — the crux of the naming trick.
        let dest = try fm.destinationOfSymbolicLink(atPath: exe.path)
        #expect(dest == realLoader.path)
        // Spawning the in-bundle path resolves through the symlink to the loader.
        #expect(fm.fileExists(atPath: exe.path))   // follows the link → the loader exists
    }

    @Test("write is idempotent and repoints a stale symlink at the current loader")
    func writeRepoints() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let old = DockAppBundle(displayName: "Steam", folderName: "Steam",
                                wineLoader: URL(fileURLWithPath: "/old/bin/wine64"))
        _ = try old.write(into: tmp.url)
        let new = DockAppBundle(displayName: "Steam", folderName: "Steam",
                                wineLoader: URL(fileURLWithPath: "/new/bin/wine64"))
        let exe = try new.write(into: tmp.url)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: exe.path) == "/new/bin/wine64")
    }
}
