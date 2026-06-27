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

    /// Replace the bottle's `steamwebhelper.exe` with Silo's wrapper so the CEF UI paints (`--single-process`
    /// — no steam.exe flag injects it). Idempotent and safe to call before every launch: Steam updates can
    /// restore the stock binary, in which case the current real one is re-preserved as `…_orig.exe`. No-op
    /// if the wine runtime doesn't ship the wrapper (older build) or Steam isn't installed yet.
    public func installWebHelperWrapper(wine: URL) throws {
        let wrapper = wine.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("share/silo/steamwebhelper-wrapper.exe")
        let helper = paths.steamBottleWebHelper
        guard fileManager.fileExists(atPath: wrapper.path),
              fileManager.fileExists(atPath: helper.path) else { return }
        if fileManager.contentsEqual(atPath: helper.path, andPath: wrapper.path) { return }   // already wrapped
        // `helper` is the real webhelper (fresh install or a Steam update): preserve it, then drop the wrapper.
        let real = helper.deletingLastPathComponent().appendingPathComponent("steamwebhelper_orig.exe")
        if fileManager.fileExists(atPath: real.path) { try fileManager.removeItem(at: real) }
        try fileManager.moveItem(at: helper, to: real)
        try fileManager.copyItem(at: wrapper, to: helper)
    }

    // MARK: - Launch

    /// Steam flags aimed at getting `steamwebhelper`'s Chromium UI to paint under Wine (without them it's
    /// a black window). `-cef-disable-gpu`/`-cef-disable-gpu-compositing` force software rendering;
    /// `-no-cef-sandbox` avoids the CEF crash-loop; `-cef-disable-chrome-runtime` selects CEF's older
    /// "alloy" runtime, which paints under Wine where the default chrome runtime doesn't. (The fully
    /// proven fix is `--single-process` injected into steamwebhelper via a wrapper — no steam.exe flag
    /// exists for it — which is what the patched-wine build adds.)
    public static let cefRenderArgs = [
        "-cef-disable-gpu", "-cef-disable-gpu-compositing", "-no-cef-sandbox", "-cef-disable-chrome-runtime",
    ]

    /// The Steam client renders into a single Wine **virtual desktop** (one NSWindow/Metal surface) — on
    /// macOS, winemac.drv's per-window layered surfaces are exactly what black-screens for CEF, and the
    /// verified recipe routes Steam through `explorer /desktop=` to sidestep that. Games still launch
    /// rootless under GPTK (so this doesn't affect gameplay).
    static let desktopGeometry = "1600x1000"

    /// Launch the bottle's Steam client detached, inside a Wine virtual desktop with the CEF-render flags
    /// so the (one-time) login window paints.
    @discardableResult
    public func launchSteam(wine: URL?, extraArgs: [String] = SteamBottle.cefRenderArgs) async throws -> Int32 {
        guard let wine else { throw BottleError.wineNotConfigured }
        let args = ["explorer", "/desktop=Silo,\(Self.desktopGeometry)", paths.steamBottleExe.path] + extraArgs
        return try await runner.spawnDetached(
            executable: wine, arguments: args,
            environment: steamEnvironment(wine: wine),
            currentDirectory: paths.steamBottleClientDir, logURL: paths.steamBottleLog)
    }

    // MARK: - Helpers

    /// Environment for launching the Steam client. `WINEMSYNC=1` matches the per-game launch env (default
    /// `EnvFlags`) so Steam and the games it co-hosts agree on the wineserver sync mode and share one
    /// wineserver. The overrides disable Steam's in-game overlay injector (a known crash/black-window
    /// source under Wine) and force builtin crypto.
    private func steamEnvironment(wine: URL) -> [String: String] {
        var env = Silo.wineEnvironment(prefix: paths.steamBottle, wine: wine)
        env["WINEMSYNC"] = "1"
        env["WINEDLLOVERRIDES"] = "gameoverlayrenderer,gameoverlayrenderer64=d;bcrypt,ncrypt=b"
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
