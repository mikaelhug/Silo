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
    private var wineBinary: URL?

    public init(bottle: SteamBottle, session: SteamClientSession) {
        self.bottle = bottle
        self.session = session
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

    /// Re-probe whether the bottle's Steam is installed (off the main actor). Called at bootstrap.
    public func refreshInstalled() async {
        let bottle = self.bottle
        // The WARMED client (steamui.dll + webhelper), not the bootstrapper — a bottle with only steam.exe
        // (interrupted warm-up) is not usable and must not gate onboarding as "ready".
        steamInstalled = await Task.detached { bottle.isClientFullyDownloaded }.value
    }

    /// Wine configured and not already busy.
    public var canSetUp: Bool { wineBinary != nil && !busy }

    /// True while the one-time Steam client self-update runs during setup (drives a progress indicator in
    /// the UI). The download can take a few minutes, so we show it's working.
    public private(set) var warmingUp = false
    /// Download progress of the warm-up, 0…1 when Steam reports it (real % bar), else nil (indeterminate).
    public private(set) var warmUpFraction: Double?

    /// Provision the bottle in the fixed order: download Steam → create the bottle →
    /// install the component set (Core Fonts, Asian fonts, d3dcompiler_47, MSVC x86/x64, msync, then the
    /// user-guided Steam client) → force-quit any Steam the installer auto-launched → WARM UP the first-run
    /// self-update → wrap the steamwebhelper. The license-bearing components (first Core Font, MSVC, Steam)
    /// show a GUI the user clicks through; the warm-up then lands the first real launch on the login screen.
    public func setUp() async {
        guard !busy else { return }
        // Refuse if the bottles' (relocated) drive is unplugged — provisioning would otherwise create a
        // phantom bottle on the boot disk at the now-missing /Volumes/... path.
        guard bottle.isRootReachable else {
            status = "Your bottles drive isn't connected. Reconnect it, then set up Steam."
            return
        }
        guard let wine = wineBinary else { status = "Set up Wine first."; return }
        busy = true
        defer { busy = false }
        do {
            // Step 3: download the Steam installer up front so a network failure surfaces before booting.
            status = "Downloading Steam…"
            _ = try await bottle.downloadSteamInstaller()
            // Step 4: create the bottle.
            status = "Creating the Steam bottle…"
            try await bottle.provision(wine: wine)
            // Apply Silo's default Wine DLL overrides (the standard Windows-compatibility set).
            status = "Configuring the bottle…"
            await bottle.applyWineDefaults(wine: wine)
            // Steps 5–11: the game-dependency component set, in order (fonts → d3dcompiler → MSVC → Steam).
            try await bottle.provisionComponents(wine: wine, onPhase: { [weak self] component in
                self?.applyComponentPhase(component)
            })
            // The user-guided Steam installer may auto-launch Steam with no CEF wrapper/virtual-desktop env
            // (→ black window) AND an untracked client. Kill whatever it spawned before the controlled warm-up.
            await bottle.forceQuit(wine: wine)
            // Fold Steam's first-run client download into setup (best-effort — never throws), then wrap the
            // steamwebhelper against the now-settled CEF dir.
            warmingUp = true
            await session.warmUpUpdate { [weak self] phase in self?.applyWarmUp(phase) }
            warmingUp = false; warmUpFraction = nil
            try? bottle.installWebHelperWrapper(wine: wine)
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

    /// User-facing status for a component-install phase. Pure + testable; user-guided steps ask the user to
    /// accept the license (the install blocks on the GUI), the rest just narrate progress.
    static func componentStatus(_ component: BottleComponent) -> String {
        component.isUserGuided
            ? "Accept the license for \(component.title), then setup continues…"
            : "Setting up Steam — installing \(component.title)…"
    }

    private func applyComponentPhase(_ component: BottleComponent) {
        status = Self.componentStatus(component)
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
        busy = true; defer { busy = false }
        // Route through the shared session so the live client has ONE owner + tracked PID (a game
        // launch afterwards reuses it instead of spawning a second client).
        let ok = await session.ensureRunning()
        status = ok
            ? "Steam launched — it may take a moment to appear."
            : "Couldn't start Steam: \(session.launchError ?? "unknown error")."
    }

    private func message(_ error: Error) -> String { (error as NSError).localizedDescription }
}
