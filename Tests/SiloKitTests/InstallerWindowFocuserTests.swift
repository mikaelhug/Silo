import Foundation
import Testing
@testable import SiloKit

@Suite("InstallerWindowFocuser")
struct InstallerWindowFocuserTests {

    @Test("isWineApp matches an executable inside the Wine runtime — not a sibling or an unrelated app")
    func isWineApp() {
        let root = URL(fileURLWithPath: "/rt/wine")
        // The loader (and its preloader sibling) live under the runtime → match.
        #expect(InstallerWindowFocuser.isWineApp(executablePath: "/rt/wine/bin/wine64", wineRoot: root))
        #expect(InstallerWindowFocuser.isWineApp(executablePath: "/rt/wine/bin/wine64-preloader", wineRoot: root))
        // A sibling runtime that merely shares the name prefix must NOT match (the trailing-slash guard).
        #expect(!InstallerWindowFocuser.isWineApp(executablePath: "/rt/wine-dxmt/bin/wine64", wineRoot: root))
        // The root itself (no child component) is not an app under it.
        #expect(!InstallerWindowFocuser.isWineApp(executablePath: "/rt/wine", wineRoot: root))
        // An unrelated app (Silo itself, Finder, …) never matches.
        #expect(!InstallerWindowFocuser.isWineApp(
            executablePath: "/Applications/Silo.app/Contents/MacOS/Silo", wineRoot: root))
    }
}
