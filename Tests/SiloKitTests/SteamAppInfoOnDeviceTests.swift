import Foundation
import Testing
@testable import SiloKit

/// Verified against the REAL `appinfo.vdf` in the bottle, because the file is a 670 KB binary the Steam
/// client writes — a hand-built fixture would only confirm my reading of the format, which is exactly the
/// mistake that let three earlier detection bugs ship.
@Suite("Steam appinfo (on-device)")
struct SteamAppInfoOnDeviceTests {
    static var enabled: Bool { ProcessInfo.processInfo.environment["SILO_BOTTLE_REPORT"] == "1" }

    @Test("Steam's own launch options are read for the installed games",
          .enabled(if: SteamAppInfoOnDeviceTests.enabled))
    func readsRealLaunchOptions() throws {
        let root = AppPaths.standard().steamBottleClientDir
        print("\n=== Steam launch options (from appinfo.vdf) ===")
        for (appID, name) in [(630, "Alien Swarm"), (317360, "Double Action"),
                              (365300, "Transmissions"), (960090, "Bloons TD 6")] {
            let entry = SteamAppInfo.windowsLaunch(steamRoot: root, appID: appID)
            print("  \(name): exe=\(entry?.executable ?? "-") args=\(entry?.arguments ?? [])")
        }
        // The three Source games are the reason this exists: each needs an argument Silo could not guess.
        let dab = try #require(SteamAppInfo.windowsLaunch(steamRoot: root, appID: 317360))
        #expect(dab.executable == "hl2.exe")
        #expect(dab.arguments == ["-game", "dab"])
        let te = try #require(SteamAppInfo.windowsLaunch(steamRoot: root, appID: 365300))
        #expect(te.arguments == ["-game", "te120"])
        let swarm = try #require(SteamAppInfo.windowsLaunch(steamRoot: root, appID: 630))
        #expect(swarm.executable == "swarm.exe")
        // A normal game with no arguments still resolves its executable — the editor entry is not chosen.
        let btd6 = try #require(SteamAppInfo.windowsLaunch(steamRoot: root, appID: 960090))
        #expect(btd6.executable == "BloonsTD6.exe")
    }
}

/// Hermetic checks for the parts that do not depend on a 670 KB binary: entry SELECTION and argument
/// splitting. The container parsing itself is verified against the real file above.
@Suite("Steam appinfo — selection")
struct SteamAppInfoSelectionTests {

    @Test("arguments split on whitespace, honouring quotes")
    func splitsArguments() {
        #expect(SteamAppInfo.splitArguments("-game dab") == ["-game", "dab"])
        #expect(SteamAppInfo.splitArguments("-novid +asw_stats_track 1") == ["-novid", "+asw_stats_track", "1"])
        #expect(SteamAppInfo.splitArguments("") == [])
        #expect(SteamAppInfo.splitArguments("  -a   -b  ") == ["-a", "-b"])
        #expect(SteamAppInfo.splitArguments("-path \"C:\\Program Files\\x\"") == ["-path", "C:\\Program Files\\x"])
    }
}
