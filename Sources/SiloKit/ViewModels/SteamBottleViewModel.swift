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

    init(bottle: SteamBottle, session: SteamClientSession) {
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
            status = "Bottles drive not connected."
            return
        }
        guard let wine = wineBinary else { status = "Set up Wine first."; return }
        busy = true
        // Kick off EVERY component's download in the BACKGROUND the moment Set up is pressed, so the slow ones
        // (Asian fonts, ~360 MB) overlap the Steam download + wineboot + earlier install steps below instead of
        // stalling their own step. `provisionComponents` awaits only the component it's about to install, and
        // narrates "Downloading…" for one whose download hasn't finished by then.
        let downloads = bottle.startSetupDownloads()
        defer { busy = false; downloads.cleanup() }
        do {
            // Step 3: download the Steam installer up front so a network failure surfaces before booting.
            status = "Downloading Steam…"
            _ = try await bottle.downloadSteamInstaller()
            // Step 4: create the bottle.
            status = "Creating bottle…"
            try await bottle.provision(wine: wine)
            // Apply Silo's default Wine DLL overrides (the standard Windows-compatibility set).
            status = "Configuring bottle…"
            await bottle.applyWineDefaults(wine: wine)
            // Steps 5–11: the game-dependency component set, in order (fonts → d3dcompiler → MSVC → Steam).
            try await bottle.provisionComponents(wine: wine, downloads: downloads, onPhase: { [weak self] component, phase in
                self?.applyComponentPhase(component, phase)
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
                ? "Steam is ready. Launch it and sign in once."
                : "Steam client didn't finish downloading. Run Set up again."
            onSteamInstalled?()   // refresh the library's cached readiness (now reflects the warmed client)
        } catch {
            warmingUp = false; warmUpFraction = nil
            status = Self.setupFailureMessage(error)
        }
    }

    /// User-facing status for a setup that didn't complete. A cancelled license installer reads as a pause
    /// (the user chose to stop) with a clear "run Set up again" cue; anything else is a plain failure.
    static func setupFailureMessage(_ error: Error) -> String {
        if case SteamBottle.BottleError.componentCancelled(let component) = error {
            return "You cancelled the \(component.title) installer. Run Set up again."
        }
        return "Setup failed: \((error as NSError).localizedDescription)"
    }

    /// User-facing status for a component-install phase. Pure + testable; user-guided steps ask the user to
    /// accept the license (the install blocks on the GUI), the rest just narrate progress.
    static func componentStatus(_ component: BottleComponent) -> String {
        component.isUserGuided
            ? "Accept the \(component.title) license…"
            : "Installing \(component.title)…"
    }

    private func applyComponentPhase(_ component: BottleComponent, _ phase: ComponentPhase) {
        status = phase == .downloading ? "Downloading \(component.title)…" : Self.componentStatus(component)
    }

    /// Map a warm-up phase to the UI status text + progress fraction.
    private func applyWarmUp(_ phase: SteamClientSession.WarmUpPhase) {
        switch phase {
        case .downloading(let fraction):
            warmUpFraction = fraction
            if let fraction {
                status = "Steam is updating itself — \(Int(fraction * 100))%…"
            } else {
                status = "Steam is updating itself…"
            }
        case .finishing:
            warmUpFraction = nil
            status = "Finishing up…"
        }
    }

    /// Forget the bottle's cached/seeded Steam login so the next launch shows a fresh login.
    public func resetLogin() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            try bottle.resetLogin()
            status = "Cleared the saved login. Launch Steam to sign in again."
        } catch {
            status = "Couldn't reset login: \(message(error))"
        }
    }

    /// Launch the bottle's Steam client. Fire-and-forget: Steam's own window is the feedback, so this shows
    /// NO spinner and NO status on success — only a failure surfaces a message. Routes through the shared
    /// session so a game launched afterwards reuses this client instead of starting a second one.
    public func launchSteam() async {
        guard !busy else { return }        // don't launch over an in-progress setup / warm-up
        status = ""                        // launching is silent; also clears any lingering setup status
        if await session.ensureRunning() == false {
            status = "Couldn't start Steam: \(session.launchError ?? "unknown error")."
        }
    }

    private func message(_ error: Error) -> String { (error as NSError).localizedDescription }
}
