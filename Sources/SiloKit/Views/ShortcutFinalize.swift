import AppKit
import Foundation

/// View-layer finishing touches for a freshly-written game shortcut `.app`: stamp a custom icon so it looks
/// like the game, then reveal it in Finder so the user sees where it landed. Kept out of the view model so
/// `GameLibraryViewModel` stays free of AppKit + networking — icon acquisition (a PE parse or a CDN fetch)
/// and `NSWorkspace` are UI concerns.
enum ShortcutFinalize {
    /// Stamp `icon` on the bundle (best-effort — a nil icon just leaves the generic app icon) and select it
    /// in Finder. `setIcon` writes the custom-icon resource directly on the file, so it needs no prior
    /// LaunchServices registration.
    @MainActor
    static func apply(icon: NSImage?, to app: URL) {
        if let icon { NSWorkspace.shared.setIcon(icon, forFile: app.path, options: []) }
        NSWorkspace.shared.activateFileViewerSelecting([app])
    }

    /// Best-effort fetch of a remote image (a Steam title's header art) as an icon. Returns nil offline or on
    /// any failure — the shortcut then simply carries the default app icon.
    static func remoteIcon(_ url: URL?) async -> NSImage? {
        guard let url, let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return NSImage(data: data)
    }
}
