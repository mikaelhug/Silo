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

    @Test("Parses package IDs from licenses_print output")
    func parseLicenses() {
        let out = """
        Licenses:
        License packageID 0 :
        	State : Active
        License packageID 54321 :
        	State : Active
        """
        #expect(SteamCMD.parseLicensePackageIDs(out) == [0, 54321])
    }

    @Test("Parses owned app IDs from a package_info_print block")
    func parsePackage() {
        let out = """
        "54321"
        {
        	"packageid"	"54321"
        	"appids"
        	{
        		"0"	"220"
        		"1"	"320"
        	}
        }
        """
        #expect(SteamCMD.parsePackageAppIDs(out, packageID: 54321) == [220, 320])
    }

    @Test("Parses live download progress (last line) + completion from a SteamCMD log")
    func progress() {
        let log = """
         Update state (0x61) downloading, progress: 41.52 (39136090106 / 94252010251)
         Update state (0x61) downloading, progress: 41.60 (39212266698 / 94252010251)
        """
        let p = try! #require(SteamCMD.parseProgress(log))
        #expect(p.done == 39212266698)
        #expect(p.total == 94252010251)
        #expect(abs(p.fraction - 0.416) < 0.01)
        #expect(!SteamCMD.isInstalledInLog(log, appID: 761890))
        #expect(SteamCMD.isInstalledInLog("Success! App '761890' fully installed.", appID: 761890))
    }

    @Test("Batch app-info builder forces Windows + updates + prints each app")
    func batchAppInfo() {
        let args = SteamCMD.appInfoArguments(appIDs: [220, 320])
        #expect(args.contains("windows"))
        #expect(args.contains("+app_info_update"))
        #expect(args.filter { $0 == "+app_info_print" }.count == 2)
    }
}
