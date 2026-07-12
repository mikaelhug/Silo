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
    /// Brings the user-guided installer/license windows to the front so the user notices them (nil in tests).
    private let focuser: GuidedInstallFocusing?
    private var wineBinary: URL?

    init(bottle: SteamBottle, session: SteamClientSession, focuser: GuidedInstallFocusing? = nil) {
        self.bottle = bottle
        self.session = session
        self.focuser = focuser
    }

    /// The Wine runtime root (`…/wine`), parent of `bin/`, used to recognise Wine's own installer windows.
    private var wineRoot: URL? {
        wineBinary?.deletingLastPathComponent().deletingLastPathComponent()
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
        // Prefetch the core-font installers in the BACKGROUND from the moment Set up is pressed, so their
        // (small but sometimes slow-mirror) download overlaps the Steam download + wineboot below instead of
        // stalling the Core Fonts step. `prefetchDone` lets the wait below surface a "Downloading…" status
        // ONLY if it's still running when we get there — a warm cache (the common case) skips that flash.
        let prefetchDone = LockedBox(false)
        let fontsPrefetch = Task.detached { [bottle, prefetchDone] in
            await bottle.prefetchCoreFonts(); prefetchDone.set(true)
        }
        // The focuser is armed per user-guided step (see `applyComponentPhase`); always disarm on exit.
        // Cancel the prefetch too: a no-op on the success path (already awaited below), but on an EARLY throw it
        // stops the detached download from outliving setUp and racing a re-run's prefetch on the same cache.
        defer { busy = false; focuser?.disarm(); fontsPrefetch.cancel() }
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
            // Make sure the background core-font prefetch has finished warming the cache before the component
            // phase consumes it. Surface "Downloading…" ONLY if it's still running (a warm cache — the common
            // case, it overlapped the steps above — goes straight through with no flash).
            if !prefetchDone.value { status = "Downloading core fonts…" }
            await fontsPrefetch.value
            // Steps 5–11: the game-dependency component set, in order (fonts → d3dcompiler → MSVC → Steam).
            try await bottle.provisionComponents(wine: wine, onPhase: { [weak self] component in
                self?.applyComponentPhase(component)
            })
            focuser?.disarm()   // installers done — stop focusing before the (windowless) warm-up
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
            status = Self.setupFailureMessage(error)
        }
    }

    /// User-facing status for a setup that didn't complete. A cancelled license installer reads as a pause
    /// (the user chose to stop) with a clear "run Set up again" cue; anything else is a plain failure.
    static func setupFailureMessage(_ error: Error) -> String {
        if case SteamBottle.BottleError.componentCancelled(let component) = error {
            return "Setup paused — you cancelled the \(component.title) installer. Run Set up again to finish."
        }
        return "Setup failed: \((error as NSError).localizedDescription)"
    }

    /// User-facing status for a component-install phase. Pure + testable; user-guided steps ask the user to
    /// accept the license (the install blocks on the GUI), the rest just narrate progress.
    static func componentStatus(_ component: BottleComponent) -> String {
        component.isUserGuided
            ? "A \(component.title) license window has opened — if it's behind Silo, press ⌘-Tab (or click it "
              + "in the Dock) to bring it forward, then accept it to continue…"
            : "Setting up Steam — installing \(component.title)…"
    }

    private func applyComponentPhase(_ component: BottleComponent) {
        status = Self.componentStatus(component)
        // Focus this step's license/installer window (user-guided steps only); drop the previous arm so a
        // headless step in between doesn't pull a stray Wine helper forward.
        focuser?.disarm()
        if component.isUserGuided, let wineRoot { focuser?.arm(wineRoot: wineRoot) }
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
