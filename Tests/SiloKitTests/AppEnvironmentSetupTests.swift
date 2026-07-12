import Foundation
import Testing
@testable import SiloKit

@MainActor
@Suite("AppEnvironment guided setup")
struct AppEnvironmentSetupTests {

    @Test("runFullSetup skips the runtime downloads when Wine + DXMT are already configured, and delegates")
    func runFullSetupSkipsRuntimesWhenReady() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        // Pre-stage the bottle so the delegated setUp does NO network and skips every component: a cached
        // SteamSetup, a warmed client (steamui + webhelper + steam.exe), and all component markers.
        try FileManager.default.createDirectory(at: paths.steamBottle, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: paths.steamBottle.appendingPathComponent("SteamSetup.exe").path, contents: Data())
        paths.createWarmedSteamClient()
        paths.createComponentMarkers()

        let runner = FakeProcessRunner()
        let env = AppEnvironment(
            paths: paths, runner: runner,
            updater: Updater(repo: "x/y", session: FakeURLProtocol.makeSession()))
        // Configure Wine + DXMT directly (bypassing bootstrap's refresh, which would clear an uninstalled
        // default). save() fires applyBackend → steamBottleVM.updateWine, so the bottle VM has its wine.
        env.backendSettings.config.wineBinaryPath = URL(fileURLWithPath: "/w/wine64")
        env.backendSettings.config.dxmtLibDirPath = tmp.url.appendingPathComponent("dxmt/lib")
        await env.backendSettings.save()
        #expect(env.wineReady && env.dxmtReady)

        await env.runFullSetup()

        // The onSteamInstalled reload is a fire-and-forget Task, so the gate flips just after setUp returns.
        for _ in 0..<200 where !env.steamReady { try await Task.sleep(for: .milliseconds(10)) }
        #expect(env.steamReady)                        // the pre-staged warmed client → ready
        #expect(!env.setupBusy)
        // NEITHER runtime download ran (both were already configured) — no attempted GitHub fetch would have
        // left a status message. This proves runFullSetup took the skip branches and delegated to setUp.
        #expect(env.runtime.statusMessage == nil)
        #expect(env.dxmtRuntime.statusMessage == nil)
        // The bottle was booted (wineboot) but never re-installed Steam (steam.exe already present → skipped).
        #expect(runner.invocations.contains { $0.arguments == ["wineboot", "--init"] })
        #expect(!runner.invocations.contains { $0.arguments.first?.hasSuffix("SteamSetup.exe") == true })
    }

    @Test("runFullSetup stops (and surfaces the real error) when the Wine install fails — no masked setUp")
    func runFullSetupStopsWhenWineInstallFails() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let runner = FakeProcessRunner()
        // A stub-less runtime session → the Wine releases fetch fails deterministically (offline, no stub).
        let env = AppEnvironment(
            paths: paths, runner: runner,
            updater: Updater(repo: "x/y", session: FakeURLProtocol.makeSession()),
            runtimeSession: FakeURLProtocol.makeSession())
        #expect(!env.wineReady)   // Wine not configured → runFullSetup will try (and fail) to install it

        await env.runFullSetup()

        #expect(!env.wineReady)                        // still unconfigured
        #expect(env.runtime.statusMessage != nil)      // the REAL install error is preserved for the UI…
        #expect(env.steamBottleVM.status.isEmpty)      // …and setUp never ran to mask it with "Set up Wine first."
        // The Steam bottle was never provisioned (no wineboot) and DXMT was never attempted.
        #expect(!runner.invocations.contains { $0.arguments == ["wineboot", "--init"] })
        #expect(env.dxmtRuntime.statusMessage == nil)
        #expect(!env.setupBusy)
    }
}
