import Foundation
import Testing
@testable import SiloKit

@Suite("SteamAppInfo parsing")
struct SteamAppInfoTests {

    // A realistic (trimmed) SteamCMD `app_info_print` dump with log preamble + trailing chatter.
    let dump = """
    Connecting anonymously to Steam Public...OK
    Waiting for user info...OK
    "70"
    {
    	"common"
    	{
    		"name"		"Half-Life"
    		"type"		"Game"
    		"oslist"		"windows,macos,linux"
    	}
    	"depots"
    	{
    		"12"
    		{
    			"config" { "oslist" "windows" }
    		}
    	}
    }
    "220"
    {
    	"common"
    	{
    		"name"		"Half-Life 2"
    		"type"		"Game"
    		"oslist"		"windows"
    	}
    }
    Unloading Steam API...OK
    """

    @Test("Parses name, platforms, type out of the noisy dump")
    func parsesOneApp() {
        let info = try! #require(SteamAppInfo.parse(appInfoOutput: dump, appID: 70))
        #expect(info.name == "Half-Life")
        #expect(info.oslist == ["windows", "macos", "linux"])
        #expect(info.type == "Game")
        #expect(info.isGame)
        #expect(info.supportsWindows)
        #expect(info.supportsMac)
        #expect(!info.isWindowsOnly)   // has a native mac build
    }

    @Test("Flags a Windows-only game (windows, no macos)")
    func windowsOnly() {
        let info = try! #require(SteamAppInfo.parse(appInfoOutput: dump, appID: 220))
        #expect(info.name == "Half-Life 2")
        #expect(info.isWindowsOnly)
    }

    @Test("parseAll extracts each requested app; filtering yields Windows-only")
    func parsesMany() {
        let all = SteamAppInfo.parseAll(appInfoOutput: dump, appIDs: [70, 220, 999])
        #expect(all.count == 2)                                  // 999 absent → skipped
        #expect(all.filter(\.isWindowsOnly).map(\.appID) == [220])
    }

    @Test("Returns nil when the app block is absent")
    func missing() {
        #expect(SteamAppInfo.parse(appInfoOutput: dump, appID: 999) == nil)
    }
}
