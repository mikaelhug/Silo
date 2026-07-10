import Foundation

/// Drives the inline app self-update flow (check → download → swap the running `.app` → relaunch) and
/// holds its UI state — the `env.updates` surface behind Settings → General → Updates and the Library
/// subtitle badge. Split out of `AppEnvironment` so the composition root doesn't also own a feature flow;
/// the `Updater` itself (network + install mechanics) is unchanged underneath.
@MainActor
@Observable
public final class UpdateCoordinator {
    /// Progress of the inline (download + self-replace + relaunch) update.
    public enum UpdateState: Sendable, Equatable {
        case idle, downloading, installing
        case failed(String)
    }

    public private(set) var updateCheck: Updater.UpdateCheck?
    public private(set) var updateState: UpdateState = .idle
    public private(set) var isCheckingForUpdate = false
    /// True while an inline update is downloading or self-replacing — it ends in `exit(0)`, so launches must
    /// be refused (a game started now would be orphaned) and a bottles move must wait.
    public var isInstalling: Bool { updateState == .downloading || updateState == .installing }

    private let updater: Updater
    /// Scratch dir the downloaded `.zip` is staged into (`AppPaths.updatesDir`).
    private let updatesDir: URL
    /// Set by AppEnvironment: true while a game or Steam client is live. A self-update relaunches Silo
    /// (which tears everything down), so it's refused while something runs.
    var isBlocked: () -> Bool = { false }

    init(updater: Updater, updatesDir: URL) {
        self.updater = updater
        self.updatesDir = updatesDir
    }

    /// Re-check GitHub for a newer app release — run automatically by `bootstrap()` and manually by the
    /// "Check Now" button. Best-effort: `updateCheck` stays nil on failure/offline.
    public func checkForUpdate() async {
        guard !isCheckingForUpdate else { return }
        isCheckingForUpdate = true
        updateCheck = try? await updater.checkForUpdate()
        isCheckingForUpdate = false
    }

    /// Apply the available update **inline** (Sparkle-style): download the release, swap the running
    /// `Silo.app` in place, and relaunch — no browser hop or manual install. No-op without a newer
    /// release; surfaces a recoverable `.failed` state when not running from an `.app` bundle (dev/CLI)
    /// or on a download/install error. On success it relaunches and never returns.
    public func installUpdate() async {
        guard let check = updateCheck, check.isNewer else { return }
        guard !isBlocked() else {
            updateState = .failed("Quit any running game first — installing an update relaunches Silo.")
            return
        }
        guard let appBundle = updater.appBundleToReplace() else {
            updateState = .failed("Silo isn't running from an installed app bundle.")
            return
        }
        updateState = .downloading
        do {
            let zip = try await updater.downloadUpdate(check, into: updatesDir)
            updateState = .installing
            try await updater.installUpdate(zip: zip, replacing: appBundle)
            await updater.relaunch(appBundle)   // launches the new build + exit(0); never returns
        } catch {
            updateState = .failed(error.localizedDescription)
        }
    }
}
