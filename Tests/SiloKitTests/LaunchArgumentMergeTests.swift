import Foundation
import Testing
@testable import SiloKit

/// Silo now supplies Steam's own launch options automatically, but every game configured BEFORE that has
/// them typed into `customArgs` by hand. Merging must not double them up.
@Suite("Launch argument merge")
struct LaunchArgumentMergeTests {

    /// The compatibility case: a game configured by hand while Silo passed nothing. Source takes the LAST
    /// `-game`, so a duplicate is not merely untidy — it decides which mod loads.
    @Test("a switch the user already set suppresses Steam's copy, values and all")
    func userSwitchWins() {
        let merged = LaunchOrchestrator.mergeArguments(steam: ["-game", "dab"],
                                                       user: ["-game", "dab", "-windowed"])
        #expect(merged == ["-game", "dab", "-windowed"])
        #expect(merged.filter { $0 == "-game" }.count == 1)

        // Even when the user pointed it somewhere else — their choice must survive, unambiguously.
        #expect(LaunchOrchestrator.mergeArguments(steam: ["-game", "dab"], user: ["-game", "hl2"])
                == ["-game", "hl2"])
    }

    /// Switches the user did NOT set still come through, so a hand-configured game keeps gaining whatever
    /// Steam knows that the user never typed.
    @Test("Steam options the user did not set are still applied")
    func steamOptionsSurvive() {
        let merged = LaunchOrchestrator.mergeArguments(steam: ["-novid", "+asw_stats_track", "1"],
                                                       user: ["-windowed"])
        #expect(merged == ["-novid", "+asw_stats_track", "1", "-windowed"])
        // Mixed: `-game` is suppressed, `-novid` is kept.
        #expect(LaunchOrchestrator.mergeArguments(steam: ["-game", "dab", "-novid"],
                                                  user: ["-game", "dab"]) == ["-novid", "-game", "dab"])
    }

    /// The ordinary cases: nothing configured, or nothing published.
    @Test("empty inputs behave")
    func emptyInputs() {
        #expect(LaunchOrchestrator.mergeArguments(steam: ["-game", "te120"], user: []) == ["-game", "te120"])
        #expect(LaunchOrchestrator.mergeArguments(steam: [], user: ["-windowed"]) == ["-windowed"])
        #expect(LaunchOrchestrator.mergeArguments(steam: [], user: []).isEmpty)
    }

    /// `+cvar value` is a Source-ism Steam uses too, so a user-set cvar must suppress Steam's value as well
    /// rather than leaving a stray number on the command line.
    @Test("+cvar switches are handled like - switches")
    func plusSwitches() {
        #expect(LaunchOrchestrator.mergeArguments(steam: ["+asw_stats_track", "1"],
                                                  user: ["+asw_stats_track", "0"]) == ["+asw_stats_track", "0"])
    }
}
