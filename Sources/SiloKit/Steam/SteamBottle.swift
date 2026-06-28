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
        environment["WINEDLLOVERRIDES"] = Silo.winePrefixInitOverrides
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
        let result = try await runner.run(
            executable: wine, arguments: [installer.path, "/S"],
            environment: Silo.wineEnvironment(prefix: paths.steamBottle, wine: wine),
            currentDirectory: paths.steamBottle)
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
        let wrapper = WineRuntimeLayout(wineBinary: wine).wrapperExe
        guard fileManager.fileExists(atPath: wrapper.path) else { return }
        // Wrap EVERY CEF dir's webhelper, not just one: a Steam update can add a new dir (e.g. cef.win64)
        // alongside the old (cef.win7x64) and switch to it, stranding a single-dir wrapper in the unused
        // one while Steam runs the unwrapped binary → black window.
        for helper in webHelpers() {
            if fileManager.contentsEqual(atPath: helper.path, andPath: wrapper.path) { continue }   // already wrapped
            let real = helper.deletingLastPathComponent().appendingPathComponent("steamwebhelper_orig.exe")
            if fileManager.fileExists(atPath: real.path) {
                // Real webhelper already preserved; `helper` is a STALE wrapper — replace just it, so we
                // never move a wrapper over the genuine `…_orig.exe`.
                try fileManager.removeItem(at: helper)
            } else {
                // `helper` is the real webhelper (fresh install or a Steam update): preserve it once.
                try fileManager.moveItem(at: helper, to: real)
            }
            try fileManager.copyItem(at: wrapper, to: helper)
        }
    }

    /// Every `steamwebhelper.exe` across the bottle's CEF dirs. The leaf name is Steam-version-dependent
    /// (`cef.win64`, `cef.win7x64`, …) and a Steam UPDATE can add a new dir alongside the old one, so we
    /// wrap them ALL — otherwise the wrapper can sit in an orphaned dir while Steam runs the unwrapped one.
    func webHelpers() -> [URL] {
        guard let dirs = try? fileManager.contentsOfDirectory(
            at: paths.steamBottleCEFDir, includingPropertiesForKeys: nil) else { return [] }
        return dirs
            .map { $0.appendingPathComponent("steamwebhelper.exe") }
            .filter { fileManager.fileExists(atPath: $0.path) }
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

    /// **Experimental** `steam.exe` flags for a *hardware-accelerated* CEF UI: the software set MINUS
    /// `-cef-disable-gpu`/`-cef-disable-gpu-compositing`, so CEF keeps its GPU process and tries to render
    /// via ANGLE → D3D11 → GPTK D3DMetal → Metal (the same path the M83 overlay made work for *games*).
    /// OPT-IN only — the default launch stays on `cefRenderArgs` (SwiftShader software GL), the verified
    /// route that paints under Wine. CEF's ANGLE D3D11 backend may not initialize under GPTK (our
    /// Electron/WebGL test failed exactly there), and even if it renders, the surface may not present — so
    /// this needs on-device validation. NOTE: games launched from the bottle are already HW-accelerated
    /// (GPTK D3DMetal); this only concerns the 2D Steam *client* UI.
    public static let cefHardwareArgs = [
        "-cef-in-process-gpu", "-cef-disable-sandbox", "-no-cef-sandbox",
        "-noverifyfiles", "-norepairfiles",
    ]

    /// Wine virtual-desktop geometry for the Steam client. On CrossOver's `winemac.drv`, the virtual-desktop
    /// ROOT window presents reliably, whereas a rootless CEF surface (SwiftShader-rendered but composited as
    /// a layered/child window) does NOT paint — it stays black even though rendering succeeds. So Steam is
    /// launched inside `explorer /desktop=` to get a presentable window. (Vineport runs rootless because
    /// Gcenx's winemac.drv handles it; CrossOver's doesn't.) Games still launch rootless under GPTK.
    public static let desktopGeometry = "1440x900"

    /// Launch the bottle's Steam client detached, inside a Wine virtual desktop (so CEF presents on
    /// CrossOver — see `desktopGeometry`). Defaults to the verified software-GL CEF flags + env;
    /// `hardwareAccelerated` switches to the experimental GPU path (see `cefHardwareArgs`).
    @discardableResult
    public func launchSteam(wine: URL?, hardwareAccelerated: Bool = false) async throws -> Int32 {
        guard let wine else { throw BottleError.wineNotConfigured }
        let cefArgs = hardwareAccelerated ? Self.cefHardwareArgs : Self.cefRenderArgs
        let args = ["explorer", "/desktop=Silo,\(Self.desktopGeometry)", paths.steamBottleExe.path] + cefArgs
        return try await runner.spawnDetached(
            executable: wine, arguments: args,
            environment: steamEnvironment(wine: wine, hardwareAccelerated: hardwareAccelerated),
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

    /// Environment for launching the Steam client — trimmed to what's actually load-bearing (verified
    /// on-device 2026-06-28). `STEAM_CEF_COMMAND_LINE` forces steamwebhelper's Chromium onto its bundled
    /// **SwiftShader software GL** (`--use-gl=swiftshader` — confirmed active in the GPU log; the route that
    /// actually paints under Wine, vs Metal/winemac.drv presentation) with `--in-process-gpu` (NOT
    /// `--single-process`, which breaks Chromium's network service). The load-bearing flag injection is the
    /// steamwebhelper wrapper (`installWebHelperWrapper`); this env is the partner that carries SwiftShader.
    /// `WINEMSYNC=1` matches the per-game launch env so Steam + co-hosted games share one wineserver (the
    /// co-residency Steamworks relies on). The winebus/SDL crash is fixed by removing libSDL2 (build
    /// `--without-sdl` + `stripBundledSDL`), NOT a DLL override; CEF presentation is the virtual desktop.
    private func steamEnvironment(wine: URL, hardwareAccelerated: Bool = false) -> [String: String] {
        var env = Silo.wineEnvironment(prefix: paths.steamBottle, wine: wine)
        env["WINEMSYNC"] = "1"
        guard hardwareAccelerated else {
            // Default (verified): force steamwebhelper's Chromium onto bundled SwiftShader software GL —
            // the route that actually paints under Wine (vs Metal/winemac.drv presentation).
            env["STEAM_CEF_COMMAND_LINE"] =
                "--no-sandbox --in-process-gpu --disable-gpu --disable-gpu-compositing "
                + "--use-gl=swiftshader --disable-software-rasterizer"
            env["STEAM_DISABLE_GPU_PROCESS"] = "1"
            return env
        }
        // EXPERIMENTAL HW path: let CEF use its GPU process (ANGLE → D3D11 → D3DMetal). Point the DYLD
        // fallbacks at the wine runtime's OVERLAID D3DMetal (same wiring a game launch uses, via
        // `wineRuntimeExternalDir`) so ANGLE's D3D11 can reach Metal, and force the d3d modules to GPTK's
        // overlaid builtins. No `--disable-gpu`/`--use-gl=swiftshader`/`STEAM_DISABLE_GPU_PROCESS`.
        // Unverified — opt-in for on-device testing (see `cefHardwareArgs`).
        let external = wine.wineRuntimeExternalDir
        env["DYLD_FALLBACK_LIBRARY_PATH"] = "\(external.path):\(wine.siloDyldFallback)"
        env["DYLD_FALLBACK_FRAMEWORK_PATH"] = external.path
        env["WINEDLLOVERRIDES"] = "d3d10,d3d11,d3d12,dxgi=b"
        // Enable the GPU process and steer ANGLE to the D3D11 backend (the one the GPTK overlay supports),
        // rather than letting it fall back to GL/SwiftShader.
        env["STEAM_CEF_COMMAND_LINE"] = "--no-sandbox --in-process-gpu --use-gl=angle --use-angle=d3d11"
        return env
    }

    private func downloadInstaller() async throws -> URL {
        let dest = paths.steamBottle.appendingPathComponent("SteamSetup.exe")
        if fileManager.fileExists(atPath: dest.path) { return dest }
        try DownloadGuard.requireHTTPS(Silo.steamInstallerURL)   // https-only download
        let (tempFile, response) = try await session.download(from: Silo.steamInstallerURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BottleError.installerDownloadFailed(http.statusCode)
        }
        try fileManager.moveItem(at: tempFile, to: dest)
        return dest
    }
}
