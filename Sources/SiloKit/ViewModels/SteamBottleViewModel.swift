import Foundation

/// Drives the Steam-bottle setup + launch (the path for Steamworks/DRM games): install Windows Steam into
/// the shared bottle and launch it (in a Wine virtual desktop with the software-GL CEF env + wrapper) for
/// a one-time sign-in, after which games run co-resident with it.
@MainActor
@Observable
public final class SteamBottleViewModel {
    public private(set) var status: String = ""
    public private(set) var busy = false

    private let bottle: SteamBottle
    /// The live Steam client is owned by the shared session (not spawned here), so the settings "Launch
    /// Steam" can't start a second, untracked client behind the Library's back.
    private let session: SteamClientSession
    /// Shared across backends: blocks setting up one bottle while another is mid-setup (see `SteamSetupGate`).
    private let setupGate: SteamSetupGate
    private var wineBinary: URL?

    public init(bottle: SteamBottle, session: SteamClientSession, setupGate: SteamSetupGate = SteamSetupGate()) {
        self.bottle = bottle
        self.session = session
        self.setupGate = setupGate
    }

    public func updateWine(_ url: URL?) {
        wineBinary = url
        session.updateWine(url)   // the session launches Steam with this wine
    }

    /// Cached (probed off-main by `refreshInstalled`; set directly by a successful `setUp`) — the bottle
    /// can live on a slow/disconnected external volume, and this gates buttons in SwiftUI bodies.
    public private(set) var steamInstalled = false
    /// Fired after `setUp` completes a fresh install — AppEnvironment reloads the library so the
    /// onboarding gate (`steamReady`) flips without an app restart.
    public var onSteamInstalled: (() -> Void)?
    /// Set by AppEnvironment: the backend running a Steam game OTHER than this bottle's, if any — so bringing
    /// this bottle's client up (settings "Launch Steam" / setUp's warm-up) can refuse a second client for
    /// the same Steam account while a game is live elsewhere.
    var otherBottleRunningGame: () -> GraphicsBackend? = { nil }
    /// Set by AppEnvironment: stop every OTHER backend's Steam client (the one-account-one-client rule).
    var stopOtherClients: () -> Void = {}

    /// Re-probe whether the bottle's Steam is installed (off the main actor). Called at bootstrap.
    public func refreshInstalled() async {
        let bottle = self.bottle
        // The WARMED client (steamui.dll + webhelper), not the bootstrapper — a bottle with only steam.exe
        // (interrupted warm-up) is not usable and must not gate onboarding as "ready".
        steamInstalled = await Task.detached { bottle.isClientFullyDownloaded }.value
    }

    /// Wine configured and nothing blocking. A DIFFERENT bottle mid-setup blocks this one — seeding from a
    /// sibling whose client is still downloading would clone a broken Steam.
    public var canSetUp: Bool { wineBinary != nil && !busy && !setupGate.isBlocked(bottle.backend) }

    /// True while the one-time Steam client self-update runs during setup (drives a progress indicator in
    /// the UI). The download can take a few minutes, so we show it's working.
    public private(set) var warmingUp = false
    /// Download progress of the warm-up, 0…1 when Steam reports it (real % bar), else nil (indeterminate).
    public private(set) var warmUpFraction: Double?

    /// Install Windows Steam into the bottle (if needed), then WARM IT UP — run Steam's first-run
    /// self-update to completion during setup so the user's first real launch lands on the login screen
    /// (instead of the "failed to load steamui.dll" → black-window → login three-launch dance). The
    /// webhelper wrapper is applied AFTER the warm-up, when the CEF dir it wraps actually exists.
    public func setUp() async {
        guard !busy else { return }
        // Refuse if the bottles' (relocated) drive is unplugged — provisioning would otherwise create a
        // phantom bottle on the boot disk at the now-missing /Volumes/... path.
        guard bottle.isRootReachable else {
            status = "Your bottles drive isn't connected. Reconnect it, then set up Steam."
            return
        }
        // A game live in the OTHER bottle would collide with setup's warm-up client (same account).
        if let other = otherBottleRunningGame() {
            status = "A game is running in the \(other.displayName) bottle — stop it before setting up Steam."
            return
        }
        // Refuse while the OTHER bottle is being set up: seeding from a sibling whose client is still
        // downloading would clone a broken Steam. One bottle at a time.
        guard !setupGate.isBlocked(bottle.backend) else {
            status = "Finish setting up the \(setupGate.inProgress?.displayName ?? "other") Steam bottle first."
            return
        }
        busy = true; setupGate.begin(bottle.backend)
        defer { busy = false; setupGate.end(bottle.backend) }
        do {
            // Fast path: if another bottle already has a complete Steam client, clone it (client + fonts)
            // instead of re-downloading ~242 MB — near-instant on APFS. Falls back to a normal install.
            if await bottle.seedFromCompleteBottle(wine: wineBinary) {
                status = "Setting up Steam from your existing install…"
            } else {
                status = "Installing Windows Steam into the bottle… (first time downloads SteamSetup)"
                try await bottle.installSteam(wine: wineBinary)
                // Fold Steam's first-run client download into setup. Best-effort — it never throws.
                warmingUp = true
                await session.warmUpUpdate { [weak self] phase in self?.applyWarmUp(phase) }
                warmingUp = false; warmUpFraction = nil
            }
            if let wine = wineBinary {
                try? bottle.installWebHelperWrapper(wine: wine)
                // Microsoft core fonts (Wine ships none) so the UI + games render text correctly.
                if !bottle.hasCoreFonts {
                    status = "Setting up Steam — installing fonts…"
                    try? await bottle.installCoreFonts(wine: wine)
                }
            }
            // Report "ready" only if the client actually WARMED (steamui.dll + webhelper). A failed or
            // interrupted warm-up leaves just the bootstrapper and must not flip the onboarding gate.
            steamInstalled = bottle.isClientFullyDownloaded
            status = steamInstalled
                ? "Steam is ready. Launch it and sign in once — it caches the login."
                : "Steam setup didn't finish downloading its client — check your connection and run Set up again."
            onSteamInstalled?()   // refresh the library's cached readiness (now reflects the warmed client)
        } catch {
            warmingUp = false; warmUpFraction = nil
            status = "Setup failed: \(message(error))"
        }
    }

    /// Map a warm-up phase to the UI status text + progress fraction.
    private func applyWarmUp(_ phase: SteamClientSession.WarmUpPhase) {
        switch phase {
        case .downloading(let fraction):
            warmUpFraction = fraction
            if let fraction {
                status = "Setting up Steam — downloading its client (\(Int(fraction * 100))%)…"
            } else {
                status = "Setting up Steam — downloading its client (one-time, this can take a few minutes)…"
            }
        case .finishing:
            warmUpFraction = nil
            status = "Setting up Steam — finishing up…"
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
        // One Steam account can't be in-game on two clients: refuse if a game is live in the OTHER bottle
        // (bringing this bottle's client up would collide), rather than silently standing up a second client.
        if let other = otherBottleRunningGame() {
            status = "A game is running in the \(other.displayName) bottle — stop it first "
                + "(one Steam account can't be in-game in two bottles at once)."
            return
        }
        busy = true; defer { busy = false }
        stopOtherClients()   // keep only THIS bottle's client online
        // Route through the shared session so the live client has ONE owner + tracked PID (a game
        // launch afterwards reuses it instead of spawning a second client).
        let ok = await session.ensureRunning()
        status = ok
            ? "Launched Steam. Give it a moment to paint, then check the bottle log."
            : "Launch failed: \(session.launchError ?? "couldn't start Steam")"
    }

    private func message(_ error: Error) -> String { (error as NSError).localizedDescription }
}

/// Serializes Steam-bottle setup across backends: while one bottle is being set up, another's setup is
/// blocked (its button disables and a direct call is refused). Prevents `SteamBottle.seedFromCompleteBottle`
/// from cloning a sibling whose client is still mid-download — which would produce a broken Steam. Shared by
/// every backend's `SteamBottleViewModel`.
@MainActor
@Observable
public final class SteamSetupGate {
    public init() {}
    /// The backend whose bottle is currently being set up, if any.
    public private(set) var inProgress: GraphicsBackend?
    func begin(_ backend: GraphicsBackend) { inProgress = backend }
    func end(_ backend: GraphicsBackend) { if inProgress == backend { inProgress = nil } }
    /// Whether a DIFFERENT bottle's setup is in progress (so `backend`'s setup must wait).
    func isBlocked(_ backend: GraphicsBackend) -> Bool { inProgress != nil && inProgress != backend }
}
