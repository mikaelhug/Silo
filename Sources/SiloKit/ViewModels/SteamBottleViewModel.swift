import Foundation

/// Drives the experimental Steam-bottle setup + launch (the revert path for Steamworks/DRM games):
/// install Windows Steam into the shared bottle and launch it (in a Wine virtual desktop with the
/// software-GL CEF env + wrapper) for a one-time sign-in, after which games run co-resident with it.
@MainActor
@Observable
public final class SteamBottleViewModel {
    public private(set) var status: String = ""
    public private(set) var busy = false

    private let bottle: SteamBottle
    /// The live Steam client is owned by the shared session (not spawned here), so the settings "Launch
    /// Steam" can't start a second, untracked client behind the Library's back.
    private let session: SteamClientSession
    private var wineBinary: URL?

    public init(bottle: SteamBottle, session: SteamClientSession) {
        self.bottle = bottle
        self.session = session
    }

    public func updateWine(_ url: URL?) {
        wineBinary = url
        session.updateWine(url)   // the session launches Steam with this wine
    }
    public var steamInstalled: Bool { bottle.isSteamInstalled }
    public var canSetUp: Bool { wineBinary != nil && !busy }

    /// Install Windows Steam into the bottle (if needed).
    public func setUp() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            status = "Installing Windows Steam into the bottle… (first time downloads SteamSetup)"
            try await bottle.installSteam(wine: wineBinary)
            if let wine = wineBinary { try? bottle.installWebHelperWrapper(wine: wine) }
            status = "Steam installed. Launch it, sign in once (it caches the login), then run a game."
        } catch {
            status = "Setup failed: \(message(error))"
        }
    }

    /// Forget the bottle's cached/seeded Steam login so the next launch shows a fresh login.
    public func resetLogin() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            try bottle.resetLogin()
            status = "Cleared the bottle's saved login. Launch Steam and sign in fresh."
        } catch {
            status = "Couldn't reset login: \(message(error))"
        }
    }

    /// Launch the bottle's Steam client.
    public func launchSteam() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        // Route through the shared session so the live client has ONE owner + tracked PID (a game
        // launch afterwards reuses it instead of spawning a second client).
        let ok = await session.ensureRunning()
        status = ok
            ? "Launched Steam. Give it a moment to paint, then check the bottle log."
            : "Launch failed: \(session.launchError ?? "couldn't start Steam")"
    }

    private func message(_ error: Error) -> String { (error as NSError).localizedDescription }
}
