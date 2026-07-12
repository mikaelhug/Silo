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
///  - **Detection by polling, not the launch notification.** A Wine GUI process forked via `Process` (not
///    LaunchServices) self-transforms into a UI app and frequently does NOT post
///    `didLaunchApplicationNotification` — and its window can appear a beat after the process starts. So while
///    armed we POLL `runningApplications` for a regular-policy app whose executable lives under `wineRoot`.
///    (The launch notification is kept as an extra immediate trigger for when it *does* fire.)
///  - **Cooperative activation.** A plain `activate()` from a helper is ignored by the focus-stealing guard
///    since macOS 14, so Silo (the active app) must YIELD activation to the Wine app first.
///
/// It only intervenes when **Silo itself** is the app sitting in front of the installer (the exact bug): if a
/// Wine window is already front, or the user deliberately switched to another app, it leaves things alone.
/// Fail-safe: if nothing matches, the window stays where macOS put it — this can only help, never regress.
@MainActor
final class InstallerWindowFocuser: GuidedInstallFocusing {
    private var wineRoot: URL?
    private var poller: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    /// How often to re-check for a Wine installer window while armed.
    private let pollInterval: Duration = .milliseconds(400)

    init() {}

    func arm(wineRoot: URL) {
        self.wineRoot = wineRoot
        if observer == nil {
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.focusWineWindow() } }
        }
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                self?.focusWineWindow()
                try? await Task.sleep(for: self?.pollInterval ?? .milliseconds(400))
            }
        }
    }

    func disarm() {
        poller?.cancel(); poller = nil
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
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
