import Foundation
import Testing
@testable import SiloKit

@Suite("Setup quality guards")
struct SetupQualityTests {

    /// A partial core-font install used to read as COMPLETE: `hasCoreFonts` keyed on `Arial.TTF`, which comes
    /// from the 2nd of 11 fonts, so a mirror hiccup (or a quit) partway through left the bottle permanently
    /// missing the rest — and every later Set up skipped the step entirely.
    @Test("core fonts are satisfied only when EVERY font installed — a partial set stays unsatisfied")
    func partialCoreFontsAreNotSatisfied() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let bottle = SteamBottle(runner: FakeProcessRunner(), paths: paths)
        let markers = paths.steamBottle.appendingPathComponent(".silo-installed")
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)

        // The old signal: the first two fonts landed (Arial among them).
        for font in Silo.coreFonts.prefix(2) {
            FileManager.default.createFile(
                atPath: markers.appendingPathComponent("corefont-\(font)").path, contents: Data())
        }
        #expect(!bottle.hasCoreFonts)                                   // partial → NOT satisfied
        #expect(bottle.unsatisfiedComponents().contains(.coreFonts))    // …and surfaced to the user

        for font in Silo.coreFonts {
            FileManager.default.createFile(
                atPath: markers.appendingPathComponent("corefont-\(font)").path, contents: Data())
        }
        #expect(bottle.hasCoreFonts)                                    // complete → satisfied
    }

    /// Setup used to report plain success over a bottle missing (say) the MSVC runtime, so the real problem
    /// resurfaced later as "every game is broken" and read as a Silo bug.
    @MainActor
    @Test("the setup outcome names components that didn't install instead of claiming success")
    func setupOutcomeNamesMissingComponents() {
        typealias VM = SteamBottleViewModel
        #expect(VM.setupOutcome(steamInstalled: true, missing: []) == "Steam is ready. Launch it and sign in once.")
        let one = VM.setupOutcome(steamInstalled: true, missing: [.vcRedistX64])
        #expect(one.contains(BottleComponent.vcRedistX64.title) && one.contains("run Set up again"))
        // Long lists stay readable.
        let many = VM.setupOutcome(steamInstalled: true, missing: [.coreFonts, .vcRedistX64, .d3dcompiler47, .sourceHanSans])
        #expect(many.contains("and 2 more"))
        // A client that never finished still takes precedence — that's the blocking problem.
        #expect(VM.setupOutcome(steamInstalled: false, missing: [.coreFonts]).contains("didn't finish downloading"))
    }

    /// NSIS returns non-zero when the user closes the Steam wizard; that used to surface as a raw installer
    /// exit code rather than the friendly "you cancelled — run Set up again" path the redist already had.
    @Test("installer cancel codes are shared so Steam and the redist agree on what 'cancelled' means")
    func installerCancelCodesShared() {
        #expect(Silo.installerCancelCodes.contains(1602))   // ERROR_INSTALL_USER_EXIT
        #expect(Silo.installerCancelCodes.contains(1223))   // ERROR_CANCELLED
        #expect(Silo.installerCancelCodes.contains(2))      // NSIS cancelled wizard
        #expect(!Silo.installerCancelCodes.contains(0))     // success is never a cancel
    }
}
