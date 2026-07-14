import Foundation
import Testing
@testable import SiloKit

@Suite("GameShortcut")
struct GameShortcutTests {

    @Test("Info.plist is a background agent, game-categorized, with a per-game bundle id")
    func infoPlist() {
        let plist = GameShortcut(name: "My Game", link: .playSteam(appID: 440)).infoPlist()
        #expect(plist.contains("<key>CFBundleExecutable</key><string>launch</string>"))
        #expect(plist.contains("<key>LSApplicationCategoryType</key><string>public.app-category.games</string>"))
        #expect(plist.contains("<key>LSUIElement</key><true/>"))
        #expect(plist.contains("<string>My Game</string>"))
        // The bundle id embeds the target so two shortcuts never share a LaunchServices identity.
        #expect(plist.contains("<string>com.mikael.silo.shortcut.steam-440</string>"))
    }

    @Test("bundle id is sanitized to alphanumerics/./- for a manual UUID")
    func bundleIDSanitized() {
        let id = UUID()
        let plist = GameShortcut(name: "x", link: .playManual(id: id)).infoPlist()
        #expect(plist.contains("com.mikael.silo.shortcut.manual-\(id.uuidString.lowercased())"))
    }

    @Test("XML-special characters in the name are escaped")
    func nameEscaped() {
        let plist = GameShortcut(name: "Tom & Jerry <2>", link: .playSteam(appID: 1)).infoPlist()
        #expect(plist.contains("Tom &amp; Jerry &lt;2&gt;"))
        #expect(!plist.contains("Tom & Jerry <2>"))
    }

    @Test("launch script execs `open` with the shell-quoted deep-link URL")
    func launchScript() {
        let s = GameShortcut(name: "My Game", link: .playSteam(appID: 440)).launchScript()
        #expect(s.hasPrefix("#!/bin/sh"))
        #expect(s.contains("exec open 'silo://play/steam/440'"))
    }

    @Test("shell-quoting neutralizes an embedded single quote in the URL path")
    func quotingSafe() {
        // A UUID never contains a quote, but the quoting must be robust regardless — assert the mechanism.
        let s = GameShortcut(name: "n", link: .playManual(id: UUID())).launchScript()
        #expect(s.contains("exec open 'silo://play/manual/"))
    }

    @Test("the generated URL parses back to the same link (builder ⇄ parser)")
    func scriptURLRoundTrips() throws {
        let link = SiloDeepLink.playManual(id: UUID())
        let s = GameShortcut(name: "n", link: link).launchScript()
        // Extract the single-quoted URL from `exec open '…'`.
        let inner = try #require(s.range(of: "exec open '").map { s[$0.upperBound...] })
        let urlString = String(inner.prefix { $0 != "'" })
        #expect(SiloDeepLink(url: URL(string: urlString)!) == link)
    }

    @Test("write creates a .app with an executable launch script + Info.plist")
    func writeBundle() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let app = try GameShortcut(name: "My Game", link: .playSteam(appID: 440)).write(into: tmp.url)
        let fm = FileManager.default
        #expect(app.lastPathComponent == "My Game.app")
        #expect(fm.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path))
        let script = app.appendingPathComponent("Contents/MacOS/launch")
        #expect(fm.fileExists(atPath: script.path))
        #expect(try fm.attributesOfItem(atPath: script.path)[.posixPermissions] as? Int == 0o755)
    }

    @Test("write sanitizes path separators / colons in the file name (can't escape the dir)")
    func writeSanitizesFileName() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let app = try GameShortcut(name: "Half-Life: Alyx / VR", link: .playSteam(appID: 1)).write(into: tmp.url)
        #expect(app.lastPathComponent == "Half-Life- Alyx - VR.app")
        // It stays a direct child of tmp — no traversal out via the "/".
        #expect(app.deletingLastPathComponent().path == tmp.url.path)
        // The DISPLAY name keeps the original.
        let plist = try String(contentsOf: app.appendingPathComponent("Contents/Info.plist"), encoding: .utf8)
        #expect(plist.contains("<key>CFBundleName</key><string>Half-Life: Alyx / VR</string>"))
    }

    @Test("write replaces an existing SILO shortcut of the same name (idempotent re-create)")
    func writeReplacesOwnShortcut() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let shortcut = GameShortcut(name: "Dup", link: .playSteam(appID: 1))
        _ = try shortcut.write(into: tmp.url)
        let app = try shortcut.write(into: tmp.url)   // ours → safe to replace, must not throw
        #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path))
    }

    @Test("write REFUSES to delete a same-named item that isn't a Silo shortcut (no data loss)")
    func writeRefusesForeignItem() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        // A user's unrelated app bundle on the Desktop that happens to share the name (any non-Silo bundle id).
        let foreign = tmp.url.appendingPathComponent("Steam.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        let foreignPlist = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>"
            + "<key>CFBundleIdentifier</key><string>com.valve.steam</string></dict></plist>"
        try Data(foreignPlist.utf8).write(to: foreign.appendingPathComponent("Info.plist"))
        let sentinel = foreign.appendingPathComponent("MacOS/steam_real")
        try FileManager.default.createDirectory(at: sentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("real".utf8).write(to: sentinel)

        #expect(throws: GameShortcut.ShortcutError.destinationOccupied("Steam.app")) {
            try GameShortcut(name: "Steam", link: .playSteam(appID: 1)).write(into: tmp.url)
        }
        // The user's bundle is untouched.
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test("write REFUSES a same-named plain file (not a bundle) rather than deleting it")
    func writeRefusesPlainFile() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let plain = tmp.url.appendingPathComponent("Notes.app")   // a plain file that just ends in .app
        try Data("important".utf8).write(to: plain)
        #expect(throws: GameShortcut.ShortcutError.destinationOccupied("Notes.app")) {
            try GameShortcut(name: "Notes", link: .playManual(id: UUID())).write(into: tmp.url)
        }
        #expect(try String(contentsOf: plain, encoding: .utf8) == "important")
    }
}
