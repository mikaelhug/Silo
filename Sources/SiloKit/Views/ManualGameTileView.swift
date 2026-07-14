import SwiftUI
import AppKit

/// A library tile for a manual (non-Steam) game. Play launches its `.exe` in the game's isolated bottle
/// under its resolved graphics backend (Automatic/GPTK/DXMT); the menu exposes Settings, Log, Wine config,
/// a Desktop shortcut, Finder, and Remove (which forgets the entry, not the files).
struct ManualGameTileView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    let game: ManualGame
    let onSettings: () -> Void
    @State private var confirmingRemove = false

    var body: some View {
        let lib = env.gameLibrary
        GameTileCard(
            title: game.name,
            isBusy: lib.isBusy(game), canLaunch: lib.canLaunch,
            helpText: "Edit settings",
            onPlay: { Task { await lib.playManual(game) } },
            onTap: onSettings
        ) {
            ManualGameArtwork(exe: game.executablePath)
        } subtitle: {
            Text("Non-Steam game").font(.caption).foregroundStyle(.secondary)
            BackendTag(choice: game.graphics)
        } menuItems: {
            menuItems()
        }
        .confirmationDialog("Remove \(game.name)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await env.gameLibrary.removeManual(game) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes it from your library. The installed files on disk are left untouched.")
        }
    }

    @ViewBuilder private func menuItems() -> some View {
        Button("Settings…", action: onSettings)
        Button("View Log") {
            openWindow(id: LogTarget.windowID,
                       value: LogTarget(title: "\(game.name) — Log", url: env.paths.manualLog(game.id)))
        }
        Button("Wine Config…") { Task { await env.gameLibrary.openManualWinecfg(game) } }
            .disabled(!env.gameLibrary.canLaunch)
        Button("Create Desktop Shortcut") {
            Task {
                guard let app = await env.gameLibrary.makeShortcut(for: game) else { return }
                // Best-effort: stamp the game's own icon (parsed from its .exe) on the shortcut, then reveal it.
                let icon = await ManualIconCache.shared.icon(for: game.executablePath)
                ShortcutFinalize.apply(icon: icon, to: app)
            }
        }
        Button("View in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([game.executablePath])
        }
        Divider()
        Button("Remove…", role: .destructive) { confirmingRemove = true }
    }
}

/// A manual game's tile artwork: the icon embedded in its `.exe` if one can be extracted, else the generic
/// placeholder. The PE is parsed off the main thread, once, and the result cached by exe path.
struct ManualGameArtwork: View {
    let exe: URL
    @State private var icon: NSImage?

    var body: some View {
        ZStack {
            GameArtworkPlaceholder()
            if let icon {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).padding(14)
            } else {
                Image(systemName: "gamecontroller.fill")
                    .font(.largeTitle).foregroundStyle(.white.opacity(0.85))
            }
        }
        .task(id: exe) { icon = await ManualIconCache.shared.icon(for: exe) }
    }
}

/// Caches extracted `.exe` icons by path so a tile (or a re-render) parses the PE at most once. A parsed
/// "no icon" result is cached too (stored as `.some(nil)`), so files without an icon aren't re-parsed.
@MainActor
final class ManualIconCache {
    static let shared = ManualIconCache()
    private var cache: [String: NSImage?] = [:]

    func icon(for exe: URL) async -> NSImage? {
        if let cached = cache[exe.path] { return cached }
        // Read + parse off the main thread (Data is Sendable); build the NSImage back on the main actor.
        let ico: Data? = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: exe, options: .mappedIfSafe) else { return nil }
            return PEIcon.icoData(fromExecutable: data)
        }.value
        let image = ico.flatMap { NSImage(data: $0) }
        cache[exe.path] = image
        return image
    }
}
