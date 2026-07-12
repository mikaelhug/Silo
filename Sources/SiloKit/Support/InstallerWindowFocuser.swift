import Foundation
import AppKit

/// Arms/disarms bringing Wine installer windows to the front during guided setup. Behind a protocol so the
/// setup view model can be unit-tested with a spy — no AppKit / `NSWorkspace` in tests.
@MainActor
protocol GuidedInstallFocusing: AnyObject {
    /// Start activating Wine GUI apps launched under `wineRoot` as they appear (idempotent).
    func arm(wineRoot: URL)
    /// Stop activating (idempotent).
    func disarm()
}

/// Brings a Wine-hosted installer/license window to the front while a guided setup step runs.
///
/// macOS leaves a window spawned by a background child process (the `wine` Silo forks to run an installer)
/// *behind* the still-active launcher, so the user can miss the license dialog they're meant to click
/// through. While armed, this observes app launches and activates the one whose executable lives inside the
/// Wine runtime tree (`wineRoot`). Fail-safe: if nothing matches, the window stays where macOS put it (the
/// prior behaviour) — this can only help, never regress.
@MainActor
final class InstallerWindowFocuser: GuidedInstallFocusing {
    private var observer: NSObjectProtocol?
    private var wineRoot: URL?

    init() {}

    func arm(wineRoot: URL) {
        self.wineRoot = wineRoot
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            // Delivered on the main queue (queue: .main), so we're already on the main actor.
            MainActor.assumeIsolated { self?.activateIfWine(app) }
        }
    }

    func disarm() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        wineRoot = nil
    }

    private func activateIfWine(_ app: NSRunningApplication?) {
        guard let app, let wineRoot, let exe = app.executableURL,
              Self.isWineApp(executablePath: exe.path, wineRoot: wineRoot) else { return }
        app.activate()
    }

    /// Whether a launched app's executable lives inside the Wine runtime tree. The trailing slash stops a
    /// sibling runtime (`…/wine-dxmt`) from matching `…/wine`.
    nonisolated static func isWineApp(executablePath: String, wineRoot: URL) -> Bool {
        executablePath.hasPrefix(wineRoot.path + "/")
    }

    // No deinit-time removal: `disarm()` is always invoked by the setUp `defer` (even on throw/cancel), and
    // this focuser lives for the whole app session — so the observer is never left dangling in practice.
}
