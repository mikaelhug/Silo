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

    /// Whether Steam's REAL client has been downloaded into the bottle — `steamui.dll` is present. A fresh
    /// `SteamSetup.exe /S` drops only the ~2 MB bootstrapper (`steam.exe`, no `steamui.dll`); the client
    /// (steamui.dll + the CEF/steamwebhelper it needs) is self-downloaded on the first run. This is the
    /// signal the warm-up (`SteamClientSession.warmUpUpdate`) waits for so the user's first real launch
    /// doesn't hit "failed to load steamui.dll".
    public var isClientDownloaded: Bool {
        fileManager.fileExists(atPath: clientDir.appendingPathComponent("steamui.dll").path)
    }

    /// The FULL client is downloaded: `steamui.dll` AND a CEF `steamwebhelper.exe` (the login UI) both
    /// present. A fresh bootstrapper has neither; the first-run self-update brings both. NB: Steam extracts
    /// these files WHILE the update is still downloading, so their presence alone is NOT "the update is
    /// done" — the warm-up ALSO waits for `updateState().committed` before shutting Steam down, or the
    /// incomplete update rolls back.
    var isClientFullyDownloaded: Bool {
        isClientDownloaded && !webHelpers().isEmpty
    }

    /// Steam's updater state parsed from its log in ONE read: the latest download progress (for a real %)
    /// and whether the update has COMMITTED. Steam logs `Update complete` only after downloading,
    /// extracting, and committing the NTFS transaction (verified in a real run) — that's the definitive
    /// "the client is installed" signal the warm-up waits for before shutting Steam down; interrupting any
    /// EARLIER rolls the half-applied update all the way back. Reads the WHOLE log (not a tail): Wine spams
    /// thousands of `msync_init Failed` lines that would push the progress lines out of any fixed window.
    /// Truncate the bottle's Steam log. The warm-up calls this before its first launch so `updateState()`'s
    /// `committed` reflects only THIS run — the log lives outside the client dir and persists across setups,
    /// so a stale `Update complete` from a prior run would otherwise fire the warm-up's completion instantly.
    func resetLog() {
        try? Data().write(to: log)
    }

    func updateState() -> (progress: (done: Int, total: Int)?, committed: Bool) {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return (nil, false) }
        let committed = text.contains("Update complete")
        for line in text.split(separator: "\n").reversed() where line.contains("Downloading update (") {
            guard let open = line.range(of: "("),
                  let ofR = line.range(of: " of ", range: open.upperBound..<line.endIndex),
                  let kbR = line.range(of: " KB", range: ofR.upperBound..<line.endIndex) else { continue }
            let done = Int(line[open.upperBound..<ofR.lowerBound].filter(\.isNumber))
            let total = Int(line[ofR.upperBound..<kbR.lowerBound].filter(\.isNumber))
            if let done, let total, total > 0 { return ((done, total), committed) }
        }
        return (nil, committed)
    }

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

    /// Whether the bottle already has Microsoft core fonts (checks a marker font). Wine installs none, so a
    /// fresh bottle is missing them.
    var hasCoreFonts: Bool {
        fileManager.fileExists(atPath:
            prefixDir.appendingPathComponent("drive_c/windows/Fonts/Arial.TTF").path)
    }

    /// Install Microsoft's core web fonts into the bottle (idempotent). Wine ships no TrueType MS fonts, so
    /// Steam's UI + many games render text with wrong/blank glyphs; this closes that gap. Each font ships as
    /// a self-extracting IExpress installer — Silo extracts its `.ttf` with Wine's built-in `/T /C /Q`
    /// extract-only (no cabextract/winetricks dependency), verified on-device, then copies it into the
    /// bottle's `windows/Fonts`. Best-effort per font: a failed download/extract is skipped, never aborting
    /// setup.
    func installCoreFonts(wine: URL?) async throws {
        guard let wine else { throw BottleError.wineNotConfigured }
        let driveC = prefixDir.appendingPathComponent("drive_c")
        let fontsDir = driveC.appendingPathComponent("windows/Fonts")
        if fileManager.fileExists(atPath: fontsDir.appendingPathComponent("Arial.TTF").path) { return }
        try fileManager.createDirectory(at: fontsDir, withIntermediateDirectories: true)

        // Download all installers CONCURRENTLY (independent ~500 KB files) — doing 11 sequential
        // round-trips was needless latency even on fast internet.
        let session = self.session
        let downloaded: [(font: String, exe: URL)] = await withTaskGroup(
            of: (font: String, exe: URL)?.self
        ) { group in
            for font in Silo.coreFonts {
                let exe = driveC.appendingPathComponent("\(font).exe")
                group.addTask {
                    let url = Silo.coreFontsBaseURL.appendingPathComponent("\(font).exe")
                    let fm = FileManager.default
                    guard (try? DownloadGuard.requireHTTPS(url)) != nil,
                          let (tempFile, response) = try? await session.download(from: url),
                          let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else { return nil }
                    try? fm.removeItem(at: exe)
                    guard (try? fm.moveItem(at: tempFile, to: exe)) != nil else { return nil }
                    return (font: font, exe: exe)
                }
            }
            var result: [(font: String, exe: URL)] = []
            for await item in group { if let item { result.append(item) } }
            return result
        }

        // Extract sequentially — concurrent wine invocations in one prefix would fight over the wineserver.
        let extractDir = driveC.appendingPathComponent("silo-fonts")
        defer { try? fileManager.removeItem(at: extractDir) }
        for (font, exe) in downloaded {
            try? fileManager.removeItem(at: extractDir)
            try? fileManager.createDirectory(at: extractDir, withIntermediateDirectories: true)
            // IExpress extract-only (`/T:<dir> /C /Q`): drops the .ttf into the target with no GUI.
            _ = try? await runner.run(
                executable: wine, arguments: ["C:\\\(font).exe", "/T:C:\\silo-fonts", "/C", "/Q"],
                environment: Silo.wineEnvironment(prefix: prefixDir, wine: wine), currentDirectory: prefixDir)
            let extracted = (try? fileManager.contentsOfDirectory(
                at: extractDir, includingPropertiesForKeys: nil)) ?? []
            for file in extracted where file.pathExtension.lowercased() == "ttf" {
                let dest = fontsDir.appendingPathComponent(file.lastPathComponent)
                try? fileManager.removeItem(at: dest)
                try? fileManager.copyItem(at: file, to: dest)
            }
            try? fileManager.removeItem(at: exe)
        }
    }

    /// If a SIBLING backend's bottle already has a complete Steam client, seed THIS bottle from it by
    /// cloning the client (+ its core fonts) instead of re-downloading ~242 MB and re-extracting fonts —
    /// the client files are identical across bottles; only the per-prefix login differs, so it's reset for
    /// a fresh sign-in. Near-instant on APFS (copy-on-write). Returns whether it seeded. Best-effort: any
    /// failure returns false so the caller falls back to a normal download install.
    func seedFromCompleteBottle(wine: URL?) async -> Bool {
        guard let wine, !isClientFullyDownloaded else { return false }
        guard let source = GraphicsBackend.allCases.first(where: {
            $0 != backend && SteamBottle(runner: runner, paths: paths, backend: $0).isClientFullyDownloaded
        }) else { return false }
        do {
            try await provision(wine: wine)   // this bottle still needs its own valid Wine prefix
            // Clone the Steam client dir (create its parent; clear any partial dst first — clonefile needs
            // the destination to not exist).
            let srcClient = paths.steamBottleClientDir(source)
            try fileManager.createDirectory(
                at: clientDir.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: clientDir.path) { try fileManager.removeItem(at: clientDir) }
            try Filesystem.clone(from: srcClient, to: clientDir, using: fileManager)
            // Clone the core fonts too (skips the per-bottle font extraction).
            let srcFonts = paths.steamBottle(source).appendingPathComponent("drive_c/windows/Fonts")
            let dstFonts = prefixDir.appendingPathComponent("drive_c/windows/Fonts")
            if fileManager.fileExists(atPath: srcFonts.appendingPathComponent("Arial.TTF").path) {
                try? fileManager.createDirectory(
                    at: dstFonts.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: dstFonts.path) { try? fileManager.removeItem(at: dstFonts) }
                try? Filesystem.clone(from: srcFonts, to: dstFonts, using: fileManager)
            }
            try? resetLogin()   // the login is per-prefix — sign in fresh in this bottle
            return true
        } catch {
            return false
        }
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

    /// Launch Steam for a one-time first-run self-update, ROOTLESS (no `explorer /desktop`) so no window is
    /// presented in the user's face during setup. TWO deliberate flag choices (both verified on-device):
    /// - **No `-silent`**: it starts Steam minimized and skips the interactive first-run bootstrap, so the
    ///   client never downloads (the bootstrapper just idles).
    /// - **No `-noverifyfiles`/`-norepairfiles`**: on a fresh bootstrapper those skip the verification that
    ///   detects the missing client and triggers the download — Steam then tries to load the not-yet-present
    ///   UI and pops the "failed to load steamui.dll" FATAL dialog before quitting. Dropping them lets Steam
    ///   verify → download → repair → install in ONE clean launch, no dialog.
    /// The download needs no window; Steam still registers its `ActiveProcess` pid regardless.
    @discardableResult
    func launchForUpdate(wine: URL?) async throws -> Int32 {
        guard let wine else { throw BottleError.wineNotConfigured }
        let args = [exe.path] + Self.cefRenderArgs.filter { $0 != "-noverifyfiles" && $0 != "-norepairfiles" }
        return try await runner.spawnDetached(
            executable: wine, arguments: args,
            environment: steamEnvironment(wine: wine),
            currentDirectory: clientDir, logURL: log)
    }

    /// Force-kill every Steam process in this bottle (`wine taskkill /F` on steamwebhelper.exe + steam.exe).
    /// Used to stop the warm-up's brought-up client: it re-execs a client Silo didn't spawn and its
    /// webhelpers hold `cef.win64/steamwebhelper.exe` open, so a graceful `-shutdown` can't reliably free
    /// the files for the wrap (verified — `-shutdown` left 7 processes alive). taskkill by image name kills
    /// them all. Runs with the bottle's msync env so it attaches to the same wineserver.
    func forceQuit(wine: URL?) async {
        guard let wine else { return }
        for image in ["steamwebhelper.exe", "steam.exe"] {
            _ = try? await runner.run(
                executable: wine, arguments: ["taskkill", "/F", "/IM", image],
                environment: steamEnvironment(wine: wine), currentDirectory: clientDir)
        }
    }

    /// Ask the running bottle Steam to quit gracefully (`steam.exe -shutdown` — lets it flush its config).
    /// Runs to completion (the transient forwarder exits quickly); the caller then waits for the client
    /// process itself to die before proceeding.
    func shutdownSteam(wine: URL?) async throws {
        guard let wine else { throw BottleError.wineNotConfigured }
        _ = try await runner.run(
            executable: wine, arguments: [exe.path, "-shutdown"],
            environment: steamEnvironment(wine: wine), currentDirectory: clientDir)
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
        var env = Silo.msyncWineEnvironment(prefix: prefixDir, wine: wine)
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
