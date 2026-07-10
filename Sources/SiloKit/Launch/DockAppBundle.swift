import Foundation

/// A tiny generated macOS `.app` wrapper whose only job is to give a Silo-launched Wine process a correctly
/// **named** Dock tile — "Steam" (or the game's name), never "wine".
///
/// macOS derives a GUI process's Dock-tile name (and menu-bar app name) from `[NSBundle mainBundle]`'s
/// `CFBundleName`, and `mainBundle` is resolved from the running executable's path **as invoked** — a
/// symlink is NOT realpath-resolved. So the bundle's `Contents/MacOS/<exe>` is a **symlink to the wine
/// loader**: spawning that in-bundle path directly makes `mainBundle` resolve to THIS `.app`, so the tile is
/// named after it. (A shell stub that `exec`s wine would replace the process image with the external loader
/// and lose the bundle identity, reverting the tile to "wine" — which is exactly why Silo's runtime launch
/// must NOT go through such a stub.) `winemac.drv` then refines the live tile icon from the game's own
/// window at runtime, so the bundle carries no icon of its own; it fixes the NAME.
///
/// Regenerated per launch (cheap) so the symlink always tracks the current runtime (the loader path moves
/// when the Wine runtime updates). Pure builders (`infoPlist`) are unit-tested; `write` performs the I/O.
public struct DockAppBundle: Sendable {
    /// The Dock-tile / menu-bar name (`CFBundleName`).
    public let displayName: String
    /// The `<folderName>.app` directory name — a stable, unique-per-game slug so co-resident games each get
    /// their own bundle (independent of the human-readable `displayName`).
    public let folderName: String
    /// The real wine loader the in-bundle executable symlinks to (`<root>/bin/wine64`).
    public let wineLoader: URL

    public init(displayName: String, folderName: String, wineLoader: URL) {
        self.displayName = displayName
        self.folderName = folderName
        self.wineLoader = wineLoader
    }

    public enum BundleError: Error, Sendable, Equatable { case writeFailed(String) }

    /// The `Contents/MacOS/` executable filename (= `CFBundleExecutable`) — the display name reduced to one
    /// path component (spaces kept, so the process name reads nicely too).
    public var executableName: String {
        let folded = displayName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return folded.isEmpty ? "Game" : folded
    }

    /// `Contents/Info.plist`. No `CFBundleIconFile` — the live icon comes from `winemac.drv` at runtime; the
    /// bundle only fixes the name. No `LSUIElement` (we WANT the Dock tile).
    public func infoPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleName</key><string>\(xmlEscaped(displayName))</string>
            <key>CFBundleDisplayName</key><string>\(xmlEscaped(displayName))</string>
            <key>CFBundleIdentifier</key><string>com.silo.dock.\(bundleSafe(folderName))</string>
            <key>CFBundleExecutable</key><string>\(xmlEscaped(executableName))</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
            <key>CFBundleShortVersionString</key><string>1.0</string>
            <key>NSHighResolutionCapable</key><true/>
            <key>LSMinimumSystemVersion</key><string>14.0</string>
        </dict>
        </plist>
        """
    }

    /// Write `<folderName>.app` into `directory`, (re)pointing `Contents/MacOS/<executableName>` at
    /// `wineLoader`. Idempotent — rewrites the plist and replaces the symlink so it tracks runtime updates.
    /// Returns the in-bundle executable URL to spawn directly.
    @discardableResult
    public func write(into directory: URL, fileManager: FileManager = .default) throws -> URL {
        let app = directory.appendingPathComponent("\(folderName).app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let exe = macOS.appendingPathComponent(executableName)
        do {
            try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
            try Data(infoPlist().utf8).write(
                to: app.appendingPathComponent("Contents/Info.plist"), options: .atomic)
            // Remove any prior link/file at the exe path (removeItem drops a symlink without following it,
            // so a stale or dangling link is cleared) before repointing at the current loader.
            try? fileManager.removeItem(at: exe)
            try fileManager.createSymbolicLink(at: exe, withDestinationURL: wineLoader)
        } catch {
            throw BundleError.writeFailed((error as NSError).localizedDescription)
        }
        return exe
    }

    // MARK: - Escaping

    private func xmlEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
    /// A bundle-id-safe slug (alphanumerics + `.`/`-` kept, anything else → `-`).
    private func bundleSafe(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        return String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }
}
