import Foundation

/// The shared "Steam bottle": one Wine prefix that hosts a logged-in **Windows Steam client** plus the
/// games that run co-resident with it. This is the post-revert model for Steamworks/DRM games —
/// Steamworks IPC is prefix-scoped, so the game and its Steam client must share a prefix.
///
/// Flow: `provision` (wineboot) → `installSteam` (silent SteamSetup.exe) → `launchSteam` → the user signs
/// in once (Steam caches it) → launch games in the same prefix. All process execution goes through the
/// `ProcessRunning` seam, so the orchestration unit-tests with no Wine/Steam present; the runtime
/// behaviour is validated on a real Mac.
public struct SteamBottle: Sendable {
    private let runner: ProcessRunning
    private let session: URLSession
    private let paths: AppPaths
    private var fileManager: FileManager { .default }

    public init(runner: ProcessRunning, session: URLSession = .shared, paths: AppPaths) {
        self.runner = runner
        self.session = session
        self.paths = paths
    }

    public enum BottleError: Error, Sendable, Equatable {
        case wineNotConfigured
        case winebootFailed(Int32)
        case installerDownloadFailed(Int)
        case steamInstallFailed(Int32)
    }

    /// Steam is installed in the bottle once `steam.exe` exists.
    public var isSteamInstalled: Bool { fileManager.fileExists(atPath: paths.steamBottleExe.path) }

    /// The bottle prefix is booted once it has a `system.reg` + `drive_c`.
    public var isProvisioned: Bool {
        let layout = PrefixLayout(prefix: paths.steamBottle)
        return fileManager.fileExists(atPath: layout.systemReg.path)
            && fileManager.fileExists(atPath: layout.driveC.path)
    }

    // MARK: - Provision + install

    /// Boot the bottle prefix (idempotent).
    public func provision(wine: URL?) async throws {
        guard let wine else { throw BottleError.wineNotConfigured }
        if isProvisioned { return }
        try fileManager.createDirectory(at: paths.steamBottle, withIntermediateDirectories: true)
        var environment = Silo.wineEnvironment(prefix: paths.steamBottle, wine: wine)
        environment["WINEDLLOVERRIDES"] = "\(Silo.winePrefixInitOverrides);\(Silo.crashyDriverOverrides)"
        let result = try await runner.run(
            executable: wine, arguments: ["wineboot", "--init"],
            environment: environment, currentDirectory: nil)
        guard result.succeeded else { throw BottleError.winebootFailed(result.exitCode) }
    }

    /// Provision the bottle and run a silent Windows Steam install into it (idempotent — no-op if Steam
    /// is already present).
    public func installSteam(wine: URL?) async throws {
        guard let wine else { throw BottleError.wineNotConfigured }
        if isSteamInstalled { return }
        try await provision(wine: wine)
        let installer = try await downloadInstaller()
        var environment = Silo.wineEnvironment(prefix: paths.steamBottle, wine: wine)
        environment["WINEDLLOVERRIDES"] = Silo.crashyDriverOverrides
        let result = try await runner.run(
            executable: wine, arguments: [installer.path, "/S"],
            environment: environment, currentDirectory: paths.steamBottle)
        guard result.succeeded else { throw BottleError.steamInstallFailed(result.exitCode) }
    }

    // MARK: - steamwebhelper wrapper

    /// Forget any cached Steam login in the bottle so the next launch shows a FRESH login. Removes
    /// `loginusers.vdf` (the auto-login account list) and Steam Guard machine tokens (`ssfn*`). Necessary
    /// because a stale/seeded login auto-retries and fails ("Received logon failure response") forever,
    /// masking a clean login. Idempotent; safe if Steam isn't installed.
    public func resetLogin() throws {
        let client = paths.steamBottleClientDir
        let loginUsers = client.appendingPathComponent("config/loginusers.vdf")
        if fileManager.fileExists(atPath: loginUsers.path) { try fileManager.removeItem(at: loginUsers) }
        let entries = (try? fileManager.contentsOfDirectory(at: client, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.lastPathComponent.hasPrefix("ssfn") {
            try? fileManager.removeItem(at: entry)
        }
    }

    /// Replace the bottle's `steamwebhelper.exe` with Silo's CEF wrapper so the UI paints. Idempotent and
    /// safe to call before every launch: handles a fresh install, a Steam update that restored the stock
    /// binary, AND a wrapper-VERSION change (e.g. new CEF flags) without corrupting the preserved original.
    /// No-op if the wine runtime doesn't ship the wrapper (older build) or Steam isn't installed yet.
    public func installWebHelperWrapper(wine: URL) throws {
        let wrapper = wine.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("share/silo/steamwebhelper-wrapper.exe")
        let helper = paths.steamBottleWebHelper
        guard fileManager.fileExists(atPath: wrapper.path),
              fileManager.fileExists(atPath: helper.path) else { return }
        if fileManager.contentsEqual(atPath: helper.path, andPath: wrapper.path) { return }   // already current
        let real = helper.deletingLastPathComponent().appendingPathComponent("steamwebhelper_orig.exe")
        if fileManager.fileExists(atPath: real.path) {
            // The real webhelper is already preserved; `helper` is a STALE wrapper (e.g. older flags) —
            // replace just it, so we never move a wrapper over the genuine `…_orig.exe`.
            try fileManager.removeItem(at: helper)
        } else {
            // `helper` is the real webhelper (fresh install or a Steam update): preserve it once.
            try fileManager.moveItem(at: helper, to: real)
        }
        try fileManager.copyItem(at: wrapper, to: helper)
    }

    // MARK: - Launch

    /// `steam.exe` flags that route its CEF UI onto software rendering so it paints under Wine (without
    /// them it's a black window). This is the **verified** Vineport set (MelonForAll/vineport, working on
    /// Apple-Silicon macOS 2026): `-cef-in-process-gpu` folds the GPU into the browser process (NOT
    /// `--single-process`, which also breaks Chromium's network service → login Transport Error), the
    /// `-cef-disable-*` flags force software GL, and `-noverifyfiles -norepairfiles` skip Steam's slow
    /// self-repair. The real software-GL switch (`--use-gl=swiftshader`) is injected via the wrapper +
    /// `STEAM_CEF_COMMAND_LINE` (see `steamEnvironment`), since no steam.exe flag carries it.
    public static let cefRenderArgs = [
        "-cef-disable-gpu", "-cef-disable-gpu-compositing", "-cef-in-process-gpu",
        "-cef-disable-sandbox", "-no-cef-sandbox", "-noverifyfiles", "-norepairfiles",
    ]

    /// Launch the bottle's Steam client detached, **rootless** (no Wine virtual desktop — Vineport runs
    /// rootless, and a virtual desktop broke mouse input here), with the CEF software-render flags + env.
    @discardableResult
    public func launchSteam(wine: URL?, extraArgs: [String] = SteamBottle.cefRenderArgs) async throws -> Int32 {
        guard let wine else { throw BottleError.wineNotConfigured }
        return try await runner.spawnDetached(
            executable: wine, arguments: [paths.steamBottleExe.path] + extraArgs,
            environment: steamEnvironment(wine: wine),
            currentDirectory: paths.steamBottleClientDir, logURL: paths.steamBottleLog)
    }

    /// Hand a `steam://…` URL to the (already-running) bottle Steam. A plain `steam.exe <url>` — no CEF
    /// flags — so Steam's single-instance forwarder routes the URL to the running client and the transient
    /// process exits, rather than standing up a second client.
    @discardableResult
    public func sendURL(_ url: String, wine: URL?) async throws -> Int32 {
        guard let wine else { throw BottleError.wineNotConfigured }
        return try await runner.spawnDetached(
            executable: wine, arguments: [paths.steamBottleExe.path, url],
            environment: steamEnvironment(wine: wine),
            currentDirectory: paths.steamBottleClientDir, logURL: paths.steamBottleLog)
    }

    // MARK: - Helpers

    /// Environment for launching the Steam client — the verified Vineport recipe. `STEAM_CEF_COMMAND_LINE`
    /// forces steamwebhelper's Chromium onto its bundled SwiftShader **software GL** renderer (the route
    /// that actually paints under Wine, rather than Metal/winemac.drv presentation), with `--in-process-gpu`
    /// (NOT `--single-process`, which breaks Chromium's network service → login Transport Error).
    /// `STEAM_DISABLE_GPU_PROCESS`/`GALLIUM_DRIVER=llvmpipe` keep all GL software-side. `WINEMSYNC=1` matches
    /// the per-game launch env so Steam + co-hosted games share one wineserver; the overrides disable the
    /// in-game overlay injector and the SDL controller bus (`Silo.crashyDriverOverrides`).
    private func steamEnvironment(wine: URL) -> [String: String] {
        var env = Silo.wineEnvironment(prefix: paths.steamBottle, wine: wine)
        env["WINEMSYNC"] = "1"
        env["WINEESYNC"] = "1"
        env["STEAM_CEF_COMMAND_LINE"] =
            "--no-sandbox --in-process-gpu --disable-gpu --disable-gpu-compositing "
            + "--use-gl=swiftshader --disable-software-rasterizer"
        env["STEAM_DISABLE_GPU_PROCESS"] = "1"
        env["GALLIUM_DRIVER"] = "llvmpipe"
        env["DOTNET_EnableWriteXorExecute"] = "0"
        env["WINEDLLOVERRIDES"] =
            "\(Silo.crashyDriverOverrides);gameoverlayrenderer,gameoverlayrenderer64=d"
        return env
    }

    private func downloadInstaller() async throws -> URL {
        let dest = paths.steamBottle.appendingPathComponent("SteamSetup.exe")
        if fileManager.fileExists(atPath: dest.path) { return dest }
        try fileManager.createDirectory(at: paths.steamBottle, withIntermediateDirectories: true)
        let (tempFile, response) = try await session.download(from: Silo.steamInstallerURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BottleError.installerDownloadFailed(http.statusCode)
        }
        try fileManager.moveItem(at: tempFile, to: dest)
        return dest
    }
}
