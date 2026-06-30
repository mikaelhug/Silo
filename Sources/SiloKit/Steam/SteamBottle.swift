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
    /// Which backend's Steam bottle this is — selects the prefix + paths (GPTK or DXMT). Each backend has
    /// its own Steam install/login, since one Steam client per prefix.
    public let backend: GraphicsBackend
    // Computed (not stored): FileManager isn't Sendable, but the shared instance is fine to use.
    private var fileManager: FileManager { .default }

    public init(
        runner: ProcessRunning, session: URLSession = .shared, paths: AppPaths,
        backend: GraphicsBackend = .gptk
    ) {
        self.runner = runner
        self.session = session
        self.paths = paths
        self.backend = backend
    }

    // This backend's bottle paths (the one place the backend selects them).
    private var prefixDir: URL { paths.steamBottle(backend) }
    private var clientDir: URL { paths.steamBottleClientDir(backend) }
    private var exe: URL { paths.steamBottleExe(backend) }
    private var cefDir: URL { paths.steamBottleCEFDir(backend) }
    private var log: URL { paths.steamBottleLog(backend) }

    public enum BottleError: Error, Sendable, Equatable {
        case wineNotConfigured
        case winebootFailed(Int32)
        case installerDownloadFailed(Int)
        case steamInstallFailed(Int32)
    }

    /// The bottle's Wine prefix.
    public var prefix: URL { prefixDir }

    /// Steam is installed in the bottle once `steam.exe` exists.
    public var isSteamInstalled: Bool { fileManager.fileExists(atPath: exe.path) }

    // MARK: - Provision + install

    /// Boot the bottle prefix (idempotent). Delegates to the shared `WinePrefixProvisioner`, re-mapping its
    /// errors to `BottleError` so callers keep one error domain.
    public func provision(wine: URL?) async throws {
        do {
            try await WinePrefixProvisioner(runner: runner).provision(prefix: prefixDir, wine: wine)
        } catch WinePrefixProvisioner.ProvisionError.wineNotConfigured {
            throw BottleError.wineNotConfigured
        } catch WinePrefixProvisioner.ProvisionError.winebootFailed(let code) {
            throw BottleError.winebootFailed(code)
        }
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
            environment: Silo.wineEnvironment(prefix: prefixDir, wine: wine),
            currentDirectory: prefixDir)
        guard result.succeeded else { throw BottleError.steamInstallFailed(result.exitCode) }
    }

    // MARK: - steamwebhelper wrapper

    /// Forget any cached Steam login in the bottle so the next launch shows a FRESH login. Removes
    /// `loginusers.vdf` (the auto-login account list) and Steam Guard machine tokens (`ssfn*`). Necessary
    /// because a stale/seeded login auto-retries and fails ("Received logon failure response") forever,
    /// masking a clean login. Idempotent; safe if Steam isn't installed.
    public func resetLogin() throws {
        let client = clientDir
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
            at: cefDir, includingPropertiesForKeys: nil) else { return [] }
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

    /// Wine virtual-desktop geometry for the Steam client. On CrossOver's `winemac.drv`, the virtual-desktop
    /// ROOT window presents reliably, whereas a rootless CEF surface (SwiftShader-rendered but composited as
    /// a layered/child window) does NOT paint — it stays black even though rendering succeeds. So Steam is
    /// launched inside `explorer /desktop=` to get a presentable window. (Vineport runs rootless because
    /// Gcenx's winemac.drv handles it; CrossOver's doesn't.) Games still launch rootless under GPTK.
    public static let desktopGeometry = "1440x900"

    /// Launch the bottle's Steam client detached, inside a Wine virtual desktop (so CEF presents on
    /// CrossOver — see `desktopGeometry`), with the verified software-GL CEF flags + env.
    @discardableResult
    public func launchSteam(wine: URL?) async throws -> Int32 {
        guard let wine else { throw BottleError.wineNotConfigured }
        let args = ["explorer", "/desktop=Silo,\(Self.desktopGeometry)", exe.path]
            + Self.cefRenderArgs
        return try await runner.spawnDetached(
            executable: wine, arguments: args,
            environment: steamEnvironment(wine: wine),
            currentDirectory: clientDir, logURL: log)
    }

    /// Hand a `steam://…` URL to the (already-running) bottle Steam. A plain `steam.exe <url>` — no CEF
    /// flags — so Steam's single-instance forwarder routes the URL to the running client and the transient
    /// process exits, rather than standing up a second client.
    @discardableResult
    public func sendURL(_ url: String, wine: URL?) async throws -> Int32 {
        guard let wine else { throw BottleError.wineNotConfigured }
        return try await runner.spawnDetached(
            executable: wine, arguments: [exe.path, url],
            environment: steamEnvironment(wine: wine),
            currentDirectory: clientDir, logURL: log)
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
    private func steamEnvironment(wine: URL) -> [String: String] {
        var env = Silo.wineEnvironment(prefix: prefixDir, wine: wine)
        env["WINEMSYNC"] = "1"
        // Force steamwebhelper's Chromium onto bundled SwiftShader software GL — the route that actually
        // paints under Wine (the GPU/Metal path black-screens; an experimental GPU path was tried and
        // removed as it never rendered).
        env["STEAM_CEF_COMMAND_LINE"] =
            "--no-sandbox --in-process-gpu --disable-gpu --disable-gpu-compositing "
            + "--use-gl=swiftshader --disable-software-rasterizer"
        env["STEAM_DISABLE_GPU_PROCESS"] = "1"
        return env
    }

    private func downloadInstaller() async throws -> URL {
        let dest = prefixDir.appendingPathComponent("SteamSetup.exe")
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
