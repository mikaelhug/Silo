import Foundation
import Testing
@testable import SiloKit

/// An OPT-IN diagnostic, not a unit test: it inspects the real Steam bottle on this machine and reports what
/// Automatic decides for each installed game (using the SAME `D3DProfile`/`BackendChooser` the launch path
/// uses, so it can't drift from production), plus what each backend ACTUALLY did according to the per-game
/// launch logs Silo already writes.
///
/// Skipped unless `SILO_BOTTLE_REPORT=1`, so hermetic runs and CI are unaffected:
///     SILO_BOTTLE_REPORT=1 Scripts/test.sh --filter BackendReport
@Suite("Backend report (on-device)")
struct BackendReportTests {

    /// A trait, not an assertion — an opt-in diagnostic must be SKIPPED on a machine without a bottle,
    /// never counted as a failure (constraint #4: the suite is green with zero runtimes installed).
    static var enabled: Bool { ProcessInfo.processInfo.environment["SILO_BOTTLE_REPORT"] == "1" }

    @Test("report: what Automatic chooses for every installed game, and why", .enabled(if: BackendReportTests.enabled))
    func automaticChoiceReport() async throws {
        let paths = AppPaths.standard()
        let config = await ConfigStore(paths: paths).load()
        let apps = try await DiscoveryEngine().discoverGames(steamRoot: paths.steamBottleClientDir)

        print("\n=== Automatic backend decisions (real library) ===")
        for app in apps.sorted(by: { $0.name < $1.name }) {
            let gameConfig = config.config(for: app.appID)
            guard let exe = LaunchOrchestrator(runner: SystemProcessRunner(), linker: GraphicsLinker())
                .resolvedExecutable(app: app, config: gameConfig) else {
                print("  \(app.name): no executable resolved"); continue
            }
            let is32 = WindowsExecutable.is32Bit(exe)
            let profile = D3DProfile.scan(executable: exe)
            let learned = gameConfig.learnedUnderRuntime == config.backend.gptkRuntimeName
                ? gameConfig.learnedBackend : nil
            let chosen = BackendChooser.choose(
                gameConfig.graphics, is32Bit: is32, profile: profile, learned: learned)

            var apis: [String] = []
            if profile.usesD3D8 { apis.append("d3d8") }
            if profile.usesD3D9 { apis.append("d3d9") }
            if profile.usesD3D1x { apis.append("d3d10/11") }
            if profile.usesD3D12 { apis.append("d3d12") }
            if profile.usesVulkan { apis.append("vulkan") }
            if profile.usesOpenGL { apis.append("opengl") }
            let why: String
            if gameConfig.graphics != .auto { why = "pinned to \(gameConfig.graphics.badge)" }
            else if profile.isD3D9Only { why = "DirectX 9 only → the sole DX9 translator" }
            else if profile.isVulkanNative { why = "Vulkan-native → needs the working MoltenVK" }
            else if is32 { why = "32-bit → GPTK is 64-bit-only" }
            else if learned != nil { why = "learned after a previous failure" }
            else { why = "default" }

            print("""
              \(app.name)
                exe      \(exe.lastPathComponent)  (\(is32 ? "32-bit" : "64-bit"))
                uses     \(apis.isEmpty ? "unknown (loads D3D dynamically)" : apis.joined(separator: ", "))
                chooses  \(chosen.badge)  — \(why)
            """)
        }
    }

    @Test("report: what each backend actually did, from the launch logs", .enabled(if: BackendReportTests.enabled))
    func actualEngagementReport() throws {
        let paths = AppPaths.standard()
        let logs = (try? FileManager.default.contentsOfDirectory(
            at: paths.logsDir, includingPropertiesForKeys: nil)) ?? []

        print("\n=== What actually happened on the last launch of each game ===")
        for log in logs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where log.pathExtension == "log" && !log.lastPathComponent.hasPrefix("steam-bottle") {
            let text = log.tailString()
            guard text.contains("Silo launch") else { continue }
            // The backend is recorded in the launch header Silo writes (its WINEDLLOVERRIDES clause). Match
            // on each backend's DISTINGUISHING token rather than the whole clause: the exact set changes
            // between Silo versions (d3d9 joined GPTK's), and a log written by an older build must still be
            // readable — that is the whole point of reading history back.
            let backend: GraphicsBackend? = {
                guard let line = text.split(separator: "\n").first(where: { $0.contains("WINEDLLOVERRIDES=") })
                else { return nil }
                if line.contains("winemetal") { return .dxmt }      // DXMT's Metal bridge, DXMT only
                if line.hasSuffix("=n") { return .dxvk }            // DXVK is the only NATIVE backend
                if line.contains("d3d12") { return .gptk }          // only D3DMetal claims d3d12
                return nil
            }()
            let verdict = backend.map { GraphicsFallback.classify(text, backend: $0) }
            print("  \(log.lastPathComponent)  backend=\(backend?.badge ?? "?")  → \(verdict.map(String.init(describing:)) ?? "n/a")")
        }
    }
}
