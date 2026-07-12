import Foundation
import AppKit

/// Arms/disarms bringing Wine installer windows to the front during guided setup. Behind a protocol so the
/// setup view model can be unit-tested with a spy — no AppKit / `NSWorkspace` in tests.
@MainActor
protocol GuidedInstallFocusing: AnyObject {
    /// Start bringing Wine GUI apps launched under `wineRoot` to the front as they appear (idempotent).
    func arm(wineRoot: URL)
    /// Stop (idempotent).
    func disarm()
}

/// Brings a Wine-hosted installer/license window to the front while a guided setup step runs.
///
/// macOS leaves a window spawned by a background child process (the `wine` Silo forks to run an installer)
/// *behind* the still-active launcher, so the user can miss the license dialog they're meant to click through.
///
/// Two things make this reliable on modern macOS, where the naive approach fails:
///  - **Event-driven detection (no polling).** A plain launch notification is unreliable here — a Wine GUI
///    process forked via `Process` (not LaunchServices) self-transforms into a UI app and frequently doesn't
///    post `didLaunchApplicationNotification`. So we ALSO KVO-observe `NSWorkspace.runningApplications`, whose
///    set changes the instant that Wine process becomes a UI app (and its window is about to appear). Either
///    signal — plus an immediate check at arm time — triggers a front attempt.
///  - **Cooperative activation.** A plain `activate()` from a helper is ignored by the focus-stealing guard
///    since macOS 14, so Silo (the active app) must YIELD activation to the Wine app first.
///
/// It only intervenes when **Silo itself** is the app sitting in front of the installer (the exact bug): if a
/// Wine window is already front, or the user deliberately switched to another app, it leaves things alone.
/// Fail-safe: if nothing matches, the window stays where macOS put it — this can only help, never regress.
@MainActor
final class InstallerWindowFocuser: GuidedInstallFocusing {
    private var wineRoot: URL?
    private var launchObserver: NSObjectProtocol?
    private var appsObservation: NSKeyValueObservation?

    init() {}

    func arm(wineRoot: URL) {
        self.wineRoot = wineRoot
        if launchObserver == nil {
            launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.focusWineWindow() } }
        }
        if appsObservation == nil {
            // Fires whenever an app joins/leaves the running-apps set — i.e. the moment a Wine process becomes
            // a UI app — which the launch notification alone can miss.
            appsObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.focusWineWindow() }
            }
        }
        focusWineWindow()   // the window may already be up when this step arms
    }

    func disarm() {
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        launchObserver = nil
        appsObservation?.invalidate(); appsObservation = nil
        wineRoot = nil
    }

    /// Bring the armed step's Wine installer/license window to the front — but ONLY when Silo itself is the app
    /// in front of it. Skips when a Wine window is already frontmost, or the user switched to some other app.
    private func focusWineWindow() {
        guard let wineRoot else { return }
        // Only intervene when SILO is the frontmost app (i.e. our launcher is the thing covering the installer).
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                == NSRunningApplication.current.processIdentifier else { return }
        guard let wineApp = NSWorkspace.shared.runningApplications.first(where: { app in
            guard app.activationPolicy == .regular, let exe = app.executableURL else { return false }
            return Self.isWineApp(executablePath: exe.path, wineRoot: wineRoot)
        }) else { return }
        // Cooperative activation: hand our active status to the Wine app, then activate all its windows.
        NSApp.yieldActivation(to: wineApp)
        wineApp.activate(options: [.activateAllWindows])
    }

    /// Whether a launched app's executable lives inside the Wine runtime tree. The trailing slash stops a
    /// sibling runtime (`…/wine-dxmt`) from matching `…/wine`.
    nonisolated static func isWineApp(executablePath: String, wineRoot: URL) -> Bool {
        executablePath.hasPrefix(wineRoot.path + "/")
    }

    // No deinit-time removal: `disarm()` is always invoked by the setUp `defer` (even on throw/cancel), and
    // this focuser lives for the whole app session — so nothing is left dangling in practice.
}
