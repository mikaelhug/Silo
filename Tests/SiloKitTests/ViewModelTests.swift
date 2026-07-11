import Foundation
import Testing
@testable import SiloKit

@MainActor
@Suite("View models")
struct ViewModelTests {

    @Test("BackendSettings save persists the config and fires onChange")
    func backendSettings() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let vm = BackendSettingsViewModel(
            config: BackendConfig(), configStore: ConfigStore(paths: paths))
        var propagated: BackendConfig?
        vm.onChange = { propagated = $0 }

        vm.config.wineBinaryPath = URL(fileURLWithPath: "/w/wine64")
        await vm.save()
        #expect(propagated?.wineBinaryPath?.path == "/w/wine64")
        #expect(await ConfigStore(paths: paths).load().backend.wineBinaryPath?.path == "/w/wine64")
    }

    @Test("GameSettings save persists the graphics choice + args, clears any earlier error")
    func gameSettingsSaveSucceeds() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let vm = GameSettingsViewModel(config: GameConfig(appID: 220), configStore: ConfigStore(paths: paths))
        vm.config.customArgs = ["-novid"]
        vm.config.graphics = .dxmt                              // the picker must actually stick
        #expect(await vm.save())
        #expect(vm.errorMessage == nil)
        let saved = await ConfigStore(paths: paths).load().config(for: 220)
        #expect(saved.customArgs == ["-novid"])
        #expect(saved.graphics == .dxmt)                        // regression guard: save() drops nothing
    }

    @Test("GameSettings save failure returns false + surfaces errorMessage (sheet must NOT dismiss)")
    func gameSettingsSaveFails() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        // A FILE where the support DIR must go → ConfigStore.save's createDirectory throws.
        let supportDir = tmp.url.appendingPathComponent("Silo")
        FileManager.default.createFile(atPath: supportDir.path, contents: Data())
        let paths = AppPaths(supportDir: supportDir)
        let vm = GameSettingsViewModel(config: GameConfig(appID: 220), configStore: ConfigStore(paths: paths))
        #expect(await vm.save() == false)
        #expect(vm.errorMessage?.contains("Couldn't save") == true)
    }

    @Test("RuntimeViewModel lists installed Wine builds")
    func runtimeVM() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        try tmp.write("Silo/Runtimes/Wine-9.0/bin/wine64", "x")
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let vm = RuntimeViewModel(
            manager: RuntimeManager(paths: paths, runner: FakeProcessRunner()), repo: "acme/wine")
        await vm.refresh()
        #expect(vm.installed.map(\.name) == ["Wine-9.0"])
        #expect(vm.installed.first?.artifact?.lastPathComponent == "wine64")
    }

    @Test("installLatest installs the newest wine-* release, ignoring app v* releases in the same repo")
    func wineReleaseFilter() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let json = """
        [
          {"tag_name":"v0.5.0","name":"Silo 0.5.0","assets":[
            {"name":"Silo.zip","browser_download_url":"https://e.com/Silo.zip","size":1}]},
          {"tag_name":"wine-cx-26.2.0","name":"Wine CX 26.2.0","assets":[
            {"name":"wine.tar.xz","browser_download_url":"https://e.com/wf.tar.xz","size":1}]}
        ]
        """
        FakeURLProtocol.stub("https://api.github.com/repos/acme/winefilter/releases?per_page=15", data: Data(json.utf8))
        FakeURLProtocol.stub("https://e.com/wf.tar.xz", data: Data("WINE".utf8))
        let fake = FakeProcessRunner()
        fake.onRun = { inv in
            if inv.executable.lastPathComponent == "tar",
               let i = inv.arguments.firstIndex(of: "-C"), i + 1 < inv.arguments.count {
                let bin = URL(fileURLWithPath: inv.arguments[i + 1]).appendingPathComponent("bin")
                try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: bin.appendingPathComponent("wine64").path, contents: Data("x".utf8))
            }
        }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let vm = RuntimeViewModel(
            manager: RuntimeManager(paths: paths, runner: fake, session: FakeURLProtocol.makeSession()),
            repo: "acme/winefilter")
        await vm.installLatest()
        #expect(vm.installed.map(\.name) == ["wine-cx-26.2.0"])
    }

    @Test("installLatest does NOT re-download when the latest Wine is already installed")
    func installLatestAlreadyInstalled() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let json = """
        [ {"tag_name":"wine-cx-26.2.0","name":"Wine CX 26.2.0","assets":[
            {"name":"wine.tar.xz","browser_download_url":"https://e.com/already.tar.xz","size":1}]} ]
        """
        FakeURLProtocol.stub("https://api.github.com/repos/acme/already/releases?per_page=15", data: Data(json.utf8))
        // Deliberately do NOT stub the asset URL — a download would fail, proving we don't attempt one.
        let fake = FakeProcessRunner()
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        // The latest build is already on disk.
        let bin = paths.runtimesDir.appendingPathComponent("wine-cx-26.2.0/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin.appendingPathComponent("wine64").path, contents: Data("x".utf8))
        let vm = RuntimeViewModel(
            manager: RuntimeManager(paths: paths, runner: fake, session: FakeURLProtocol.makeSession()),
            repo: "acme/already")
        await vm.refresh()                                   // installed now lists wine-cx-26.2.0

        await vm.installLatest()

        #expect(vm.statusMessage?.contains("already installed") == true)
        #expect(vm.installed.map(\.name) == ["wine-cx-26.2.0"])             // unchanged
        #expect(!fake.invocations.contains { $0.executable.lastPathComponent == "tar" })   // no extraction
    }

    @Test("installLatest reports 'No Wine build published' when the repo has no wine-* release")
    func installLatestNoWineRelease() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let json = """
        [{"tag_name":"v0.5.0","name":"Silo 0.5.0","assets":[
          {"name":"Silo.zip","browser_download_url":"https://e.com/Silo.zip","size":1}]}]
        """
        FakeURLProtocol.stub("https://api.github.com/repos/acme/noWine/releases?per_page=15", data: Data(json.utf8))
        let vm = RuntimeViewModel(
            manager: RuntimeManager(paths: paths, runner: FakeProcessRunner(), session: FakeURLProtocol.makeSession()),
            repo: "acme/noWine")
        await vm.installLatest()
        #expect(vm.statusMessage?.contains("No Wine build published") == true)
        #expect(!vm.isInstalling)
    }

    @Test("installLatest reports 'no installable archive' when the wine-* release has no archive asset")
    func installLatestNoAsset() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let json = """
        [{"tag_name":"wine-cx-26.2.0","name":"Wine CX 26.2.0","assets":[]}]
        """
        FakeURLProtocol.stub("https://api.github.com/repos/acme/noAsset/releases?per_page=15", data: Data(json.utf8))
        let vm = RuntimeViewModel(
            manager: RuntimeManager(paths: paths, runner: FakeProcessRunner(), session: FakeURLProtocol.makeSession()),
            repo: "acme/noAsset")
        await vm.installLatest()
        #expect(vm.statusMessage?.contains("no installable archive") == true)
        #expect(!vm.isInstalling)
    }

    // MARK: - DXMT kind (the SAME RuntimeViewModel, parameterized for DXMT)

    /// A fake tar that writes a DXMT `x86_64-windows` module tree into the extract dir.
    private func dxmtExtractHook(_ fake: FakeProcessRunner) {
        fake.onRun = { inv in
            if inv.executable.lastPathComponent == "tar",
               let i = inv.arguments.firstIndex(of: "-C"), i + 1 < inv.arguments.count {
                let win = URL(fileURLWithPath: inv.arguments[i + 1]).appendingPathComponent("lib/wine/x86_64-windows")
                try? FileManager.default.createDirectory(at: win, withIntermediateDirectories: true)
                for f in ["d3d11.dll", "winemetal.dll"] {
                    FileManager.default.createFile(atPath: win.appendingPathComponent(f).path, contents: Data("x".utf8))
                }
            }
        }
    }

    @Test("DXMT installLatest installs the wine-matched dxmt-*-cx release and adopts it as default")
    func dxmtInstallLatest() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        // Newest-first: two DXMT builds (per-wine) + a wine + an app tag. The kind must pick the one
        // matched to the configured wine, NOT the newest.
        let json = """
        [{"tag_name":"dxmt-v0.72-cx26.3.0","name":"DXMT","assets":[
            {"name":"n.tar.xz","browser_download_url":"https://e.com/newer.tar.xz","size":1}]},
         {"tag_name":"wine-cx-26.2.0","name":"Wine","assets":[]},
         {"tag_name":"dxmt-v0.72-cx26.2.0","name":"DXMT","assets":[
            {"name":"m.tar.xz","browser_download_url":"https://e.com/matched.tar.xz","size":1}]},
         {"tag_name":"v0.5.0","name":"Silo","assets":[]}]
        """
        FakeURLProtocol.stub("https://api.github.com/repos/acme/dxmt/releases?per_page=30", data: Data(json.utf8))
        FakeURLProtocol.stub("https://e.com/matched.tar.xz", data: Data("DXMT".utf8))
        let fake = FakeProcessRunner(); dxmtExtractHook(fake)
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let manager = RuntimeManager(paths: paths, runner: fake, session: FakeURLProtocol.makeSession())
        let vm = RuntimeViewModel(
            kind: .dxmt(manager: manager, wineRuntimeName: { "wine-cx-26.2.0" }),
            manager: manager, repo: "acme/dxmt")
        var adopted: RuntimeInstall?
        vm.onDefaultChanged = { adopted = $0 }

        await vm.installLatest()

        #expect(vm.installed.map(\.name) == ["dxmt-v0.72-cx26.2.0"])     // the matched build
        #expect(vm.defaultName == "dxmt-v0.72-cx26.2.0")                 // adopted (none was set)
        #expect(adopted?.artifact?.lastPathComponent == "x86_64-windows")
        #expect(vm.statusMessage?.contains("Installed") == true)
    }

    @Test("DXMT installLatest reports 'No DXMT build published' when only wine releases exist")
    func dxmtInstallLatestNoRelease() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let json = #"[{"tag_name":"wine-cx-26.2.0","name":"Wine","assets":[]}]"#
        FakeURLProtocol.stub("https://api.github.com/repos/acme/dxmtnone/releases?per_page=30", data: Data(json.utf8))
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let manager = RuntimeManager(paths: paths, runner: FakeProcessRunner(), session: FakeURLProtocol.makeSession())
        let vm = RuntimeViewModel(
            kind: .dxmt(manager: manager, wineRuntimeName: { nil }),
            manager: manager, repo: "acme/dxmtnone")
        await vm.installLatest()
        #expect(vm.statusMessage?.contains("No DXMT build published") == true)
        #expect(!vm.isInstalling)
    }

    @Test("DXMT installLatest does NOT re-download when already installed")
    func dxmtInstallLatestAlready() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let json = #"[{"tag_name":"dxmt-v0.72-cx26.2.0","name":"DXMT","assets":[{"name":"d.tar.xz","browser_download_url":"https://e.com/already-dxmt.tar.xz","size":1}]}]"#
        FakeURLProtocol.stub("https://api.github.com/repos/acme/dxmtalready/releases?per_page=30", data: Data(json.utf8))
        // Deliberately do NOT stub the asset — a download would fail, proving we don't attempt one.
        let fake = FakeProcessRunner()
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let win = paths.runtimesDir.appendingPathComponent("dxmt-v0.72-cx26.2.0/lib/wine/x86_64-windows")
        try FileManager.default.createDirectory(at: win, withIntermediateDirectories: true)
        for f in ["d3d11.dll", "winemetal.dll"] {
            FileManager.default.createFile(atPath: win.appendingPathComponent(f).path, contents: Data("x".utf8))
        }
        let manager = RuntimeManager(paths: paths, runner: fake, session: FakeURLProtocol.makeSession())
        let vm = RuntimeViewModel(
            kind: .dxmt(manager: manager, wineRuntimeName: { "wine-cx-26.2.0" }),
            manager: manager, repo: "acme/dxmtalready")
        await vm.refresh()

        await vm.installLatest()

        #expect(vm.statusMessage?.contains("already installed") == true)
        #expect(vm.installed.map(\.name) == ["dxmt-v0.72-cx26.2.0"])
        #expect(!fake.invocations.contains { $0.executable.lastPathComponent == "tar" })
    }

    @Test("AppEnvironment.setupComplete needs Wine + GPTK + the Steam bottle")
    func setupComplete() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let env = AppEnvironment(paths: paths, runner: FakeProcessRunner())
        #expect(!env.setupComplete)
        env.backendSettings.config.wineBinaryPath = URL(fileURLWithPath: "/w/wine64")
        env.backendSettings.config.gptkLibDirPath = URL(fileURLWithPath: "/g/lib")
        #expect(!env.setupComplete)                       // Steam not installed in the bottle yet
        paths.createWarmedSteamClient()
        #expect(!env.setupComplete)                       // steamReady is a CACHE — not probed yet
        await env.gameLibrary.refreshSteamInstalled()
        #expect(env.setupComplete)
        #expect(env.wineReady && env.gptkReady && env.steamReady)
    }

    @Test("AppEnvironment bootstraps from persisted config")
    func appEnvironment() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        var backend = BackendConfig()
        backend.wineBinaryPath = URL(fileURLWithPath: "/w/wine64")
        try await ConfigStore(paths: paths).saveBackend(backend)

        let env = AppEnvironment(
            paths: paths, runner: FakeProcessRunner(),
            updater: Updater(repo: "x/y", session: FakeURLProtocol.makeSession()))
        await env.bootstrap()
        #expect(env.didBootstrap)
        #expect(env.backendSettings.config.wineBinaryPath?.path == "/w/wine64")
        #expect(env.gameLibrary.canLaunch)
        #expect(env.updates.updateCheck == nil)
    }

    @Test("ExecutableResolver.allExecutables lists exes shallowest-first")
    func allExecutables() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let game = try tmp.makeDir("G")
        try tmp.write("G/Game.exe", "x")
        try tmp.write("G/redist/vcredist.exe", "x")
        let list = ExecutableResolver.allExecutables(in: game)
        #expect(list.first == "Game.exe")
        #expect(list.contains("redist/vcredist.exe"))
    }
}
