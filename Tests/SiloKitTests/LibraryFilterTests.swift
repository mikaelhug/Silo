import Foundation
import Testing
@testable import SiloKit

@Suite("Library filtering")
struct LibraryFilterTests {

    /// REGRESSION, pinned against the REAL manifest from a live bottle (`Fixtures/appmanifest_228980_real.acf`).
    /// The old filter assumed Steam writes `LastOwner == 0` for shared packages; the real manifest carries the
    /// owner's actual SteamID64, so the check never fired and "Steamworks Common Redistributables" was listed
    /// as a game. Using the real bytes means this can't regress to another guess about the file's shape.
    @Test("the real Steamworks Common Redistributables manifest is filtered out of the library")
    func realRedistributableManifestIsHidden() throws {
        let acf = try FixtureLoader.text("appmanifest_228980_real.acf")
        let app = try AppManifestDecoder().decode(text: acf, libraryPath: URL(fileURLWithPath: "/lib"))

        #expect(app.name == "Steamworks Common Redistributables")
        #expect(app.lastOwner == 76561198033998487)   // NOT 0 — exactly why the old heuristic failed
        #expect(app.isFullyInstalled)                 // and it IS installed, so that alone can't hide it
        #expect(app.isSharedSystemApp)                // …yet it's correctly excluded
    }

    /// The other half: a real game must NEVER be hidden. Split Fiction is the case the notes warned about —
    /// it keeps its executables nested, so any exe-presence heuristic would wrongly drop it.
    @Test("a real game is never treated as a shared package")
    func realGameIsNotFiltered() {
        for (id, name) in [(2001120, "Split Fiction"), (960090, "Bloons TD 6"), (1276390, "Bloons TD Battles 2")] {
            let app = SteamApp(appID: id, name: name, installDir: name, stateFlags: .fullyInstalled,
                               sizeOnDisk: 1, lastOwner: 76561198033998487,
                               libraryPath: URL(fileURLWithPath: "/lib"))
            #expect(!app.isSharedSystemApp, "\(name) must stay in the library")
        }
    }

    /// Only games Steam reports as INSTALLED are listed — one mid-download has no complete files, so showing
    /// it as playable only yields a launch that fails on a missing executable.
    @Test("a game that is still downloading is not listed as playable")
    func downloadingGameIsNotFullyInstalled() {
        let downloading = SteamApp(appID: 42, name: "Downloading", installDir: "D",
                                   stateFlags: StateFlags(rawValue: 1_048_576 | 2), sizeOnDisk: 0,
                                   libraryPath: URL(fileURLWithPath: "/lib"))
        #expect(!downloading.isFullyInstalled)
        // An installed game with an update pending still counts as installed (its files are there).
        let updatePending = SteamApp(appID: 43, name: "Update pending", installDir: "U",
                                     stateFlags: StateFlags(rawValue: 4 | 2), sizeOnDisk: 1,
                                     libraryPath: URL(fileURLWithPath: "/lib"))
        #expect(updatePending.isFullyInstalled)
    }
}
