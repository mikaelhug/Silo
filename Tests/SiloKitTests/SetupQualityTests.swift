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
        let fonts = paths.steamBottle.appendingPathComponent("drive_c/windows/Fonts")
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)

        // Only the first two packages' fonts landed (Arial among them).
        for font in Silo.coreFonts.prefix(2) {
            FileManager.default.createFile(
                atPath: fonts.appendingPathComponent(Silo.coreFontWitness[font]!).path, contents: Data("TTF".utf8))
        }
        #expect(!bottle.hasCoreFonts)                                   // partial → NOT satisfied
        #expect(bottle.unsatisfiedComponents().contains(.coreFonts))    // …and surfaced to the user

        for font in Silo.coreFonts {
            FileManager.default.createFile(
                atPath: fonts.appendingPathComponent(Silo.coreFontWitness[font]!).path, contents: Data("TTF".utf8))
        }
        #expect(bottle.hasCoreFonts)                                    // complete → satisfied
    }

    /// REGRESSION, from the real bottle (2026-08-04): all 58 fonts were installed and Silo still reported
    /// "Core Fonts" unsatisfied, because the predicate looked for per-font MARKER files that a since-changed
    /// installer had never written. Setup then re-downloaded and re-ran all 11 packages, and the honest
    /// "these components failed" list cried wolf — which is how a genuine failure beside it stayed invisible.
    /// The component is about fonts; ask about fonts.
    @Test("fonts present with NO marker files satisfy the component")
    func fontsWithoutMarkersAreSatisfied() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let bottle = SteamBottle(runner: FakeProcessRunner(), paths: paths)
        let fonts = paths.steamBottle.appendingPathComponent("drive_c/windows/Fonts")
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        for name in Silo.coreFontWitness.values {
            FileManager.default.createFile(atPath: fonts.appendingPathComponent(name).path, contents: Data("TTF".utf8))
        }
        #expect(FileManager.default.fileExists(
            atPath: paths.steamBottle.appendingPathComponent(".silo-installed").path) == false)
        #expect(bottle.hasCoreFonts)
        #expect(!bottle.unsatisfiedComponents().contains(.coreFonts))
    }

    /// The d3dcompiler_47 component exists to place MICROSOFT's DLL. Wine's own builtin is copied into
    /// system32 by `wineboot` regardless, so the predicate must not accept it — on the real bottle the
    /// files were byte-identical to wine's builtins (371,433 / 325,292 bytes) after an install that had
    /// silently done nothing.
    @Test("wine's builtin d3dcompiler_47 does not satisfy the component")
    func wineBuiltinDoesNotSatisfyD3DCompiler() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let bottle = SteamBottle(runner: FakeProcessRunner(), paths: paths)
        for (abi, size) in [("system32", 371_433), ("syswow64", 325_292)] {   // wine's real builtin sizes
            let dir = paths.steamBottle.appendingPathComponent("drive_c/windows/\(abi)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: dir.appendingPathComponent("d3dcompiler_47.dll").path,
                                          contents: Data(count: size))
        }
        #expect(!bottle.hasD3DCompiler47)
        #expect(bottle.unsatisfiedComponents().contains(.d3dcompiler47))
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

    /// The marker used to be a bare "exists" flag, so an override ADDED in a later Silo release never
    /// reached bottles that were already set up — they kept the old set forever.
    @Test("the wine-defaults marker is content-stamped, stable across processes, and re-applies on change")
    func wineDefaultsAreVersioned() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let bottle = SteamBottle(runner: FakeProcessRunner(), paths: paths)
        let markers = paths.steamBottle.appendingPathComponent(".silo-installed")
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        let marker = markers.appendingPathComponent("wine-defaults")

        // A legacy (empty) marker must NOT count — that's the case that stranded old bottles.
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        #expect(!bottle.hasWineDefaults)

        try Data(SteamBottle.wineDefaultsStamp.utf8).write(to: marker)
        #expect(bottle.hasWineDefaults)
        // A different set (simulated by a different stamp) re-applies.
        try Data("99:deadbeef".utf8).write(to: marker)
        #expect(!bottle.hasWineDefaults)
        // Stable within a process AND deterministic — String.hashValue would NOT be (randomly seeded).
        #expect(SteamBottle.wineDefaultsStamp == SteamBottle.wineDefaultsStamp)
        #expect(!SteamBottle.wineDefaultsStamp.contains("-"))   // a digest, never a negative hashValue
    }

    /// wineboot creates drive_c + system.reg EARLY, long before it finishes populating the prefix. Quitting
    /// in that window used to mark the prefix "provisioned" forever, so every later Set up silently built on
    /// a half-booted prefix with no way to repair it.
    @Test("an interrupted wineboot is retried, not mistaken for a booted prefix")
    func interruptedWinebootIsRetried() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let fm = FileManager.default
        let prefix = tmp.url.appendingPathComponent("bottle")
        let provisioner = WinePrefixProvisioner(runner: FakeProcessRunner())

        // The skeleton wineboot creates within its first moments.
        let sys32 = prefix.appendingPathComponent("drive_c/windows/system32")
        try fm.createDirectory(at: sys32, withIntermediateDirectories: true)
        fm.createFile(atPath: prefix.appendingPathComponent("system.reg").path, contents: Data())
        #expect(!provisioner.isProvisioned(prefix))          // half-booted → must re-boot

        // A completed boot records a marker.
        let marker = WinePrefixProvisioner.bootMarker(prefix)
        try fm.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: marker.path, contents: Data())
        #expect(provisioner.isProvisioned(prefix))

        // Legacy prefixes (booted before the marker existed) are still recognised by a populated system32.
        try fm.removeItem(at: marker)
        for i in 0..<60 { fm.createFile(atPath: sys32.appendingPathComponent("d\(i).dll").path, contents: Data()) }
        #expect(provisioner.isProvisioned(prefix))
    }
}
