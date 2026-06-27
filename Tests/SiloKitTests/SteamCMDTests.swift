import Foundation
import Testing
@testable import SiloKit

@Suite("SteamCMD command builders")
struct SteamCMDTests {

    @Test("Download forces the Windows platform, sets the install dir, validates, and quits")
    func download() {
        let dir = URL(fileURLWithPath: "/lib/Half-Life 2")
        let args = SteamCMD.downloadArguments(appID: 220, username: "alice", installDir: dir)
        #expect(args == [
            "+login", "alice",
            "+force_install_dir", "/lib/Half-Life 2",
            "+@sSteamCmdForcePlatformType", "windows",
            "+app_update", "220", "validate", "+quit",
        ])
        // Force-platform must precede app_update, or SteamCMD grabs the host (macOS) depot.
        let force = args.firstIndex(of: "+@sSteamCmdForcePlatformType")!
        let update = args.firstIndex(of: "+app_update")!
        #expect(force < update)
    }

    @Test("App-info uses anonymous login and forces Windows metadata")
    func appInfo() {
        let args = SteamCMD.appInfoArguments(appID: 70)
        #expect(args.contains("anonymous"))
        #expect(args.contains("+app_info_print"))
        #expect(args.contains("70"))
        #expect(args.contains("windows"))
        #expect(args.last == "+quit")
    }

    @Test("Licenses lists owned packages for a logged-in user")
    func licenses() {
        #expect(SteamCMD.licensesArguments(username: "bob") == ["+login", "bob", "+licenses_print", "+quit"])
    }
}
