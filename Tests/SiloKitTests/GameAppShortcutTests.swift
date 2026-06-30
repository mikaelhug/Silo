import Foundation
import Testing
@testable import SiloKit

@Suite("GameAppShortcut")
struct GameAppShortcutTests {

    private func shortcut(name: String = "My Game") -> GameAppShortcut {
        let plan = LaunchPlan(
            executable: URL(fileURLWithPath: "/rt/bin/wine64"),
            arguments: ["/games/My Game/game.exe", "-windowed"],
            environment: ["WINEPREFIX": "/b/m", "WINEMSYNC": "1", "WINEDLLOVERRIDES": "d3d11=b"],
            currentDirectory: URL(fileURLWithPath: "/games/My Game"),
            logURL: URL(fileURLWithPath: "/l/m.log"))
        return GameAppShortcut(name: name, plan: plan)
    }

    @Test("Info.plist is categorized as a game and runs the launch script")
    func infoPlist() {
        let plist = shortcut().infoPlist()
        #expect(plist.contains("<key>LSApplicationCategoryType</key><string>public.app-category.games</string>"))
        #expect(plist.contains("<key>CFBundleExecutable</key><string>launch</string>"))
        #expect(plist.contains("<string>My Game</string>"))
    }

    @Test("launch script exports the env (sorted, shell-quoted), cds, and execs wine")
    func launchScript() throws {
        let s = shortcut().launchScript()
        #expect(s.hasPrefix("#!/bin/sh"))
        #expect(s.contains("export WINEPREFIX='/b/m'"))
        #expect(s.contains("export WINEMSYNC='1'"))
        #expect(s.contains("export WINEDLLOVERRIDES='d3d11=b'"))
        #expect(s.contains("cd '/games/My Game' || exit 1"))
        #expect(s.contains("exec '/rt/bin/wine64' '/games/My Game/game.exe' '-windowed'"))
        // env exports are sorted: WINEDLLOVERRIDES before WINEPREFIX
        let dll = try #require(s.range(of: "export WINEDLLOVERRIDES"))
        let pre = try #require(s.range(of: "export WINEPREFIX"))
        #expect(dll.lowerBound < pre.lowerBound)
    }

    @Test("shell-quoting neutralizes an embedded single quote")
    func quoting() {
        let plan = LaunchPlan(
            executable: URL(fileURLWithPath: "/w"), arguments: [],
            environment: ["X": "a'b"], currentDirectory: URL(fileURLWithPath: "/c"),
            logURL: URL(fileURLWithPath: "/l"))
        #expect(GameAppShortcut(name: "n", plan: plan).launchScript().contains(#"export X='a'\''b'"#))
    }

    @Test("write creates a .app with an executable launch script")
    func writeBundle() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let app = try shortcut(name: "My Game").write(into: tmp.url)
        let fm = FileManager.default
        #expect(app.lastPathComponent == "My Game.app")
        #expect(fm.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path))
        let script = app.appendingPathComponent("Contents/MacOS/launch")
        #expect(fm.fileExists(atPath: script.path))
        #expect(try fm.attributesOfItem(atPath: script.path)[.posixPermissions] as? Int == 0o755)
    }
}
