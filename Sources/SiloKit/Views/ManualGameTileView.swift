import SwiftUI
import AppKit

/// A library tile for a manual (non-Steam) game. Play launches its `.exe` in the bottle under GPTK; the
/// menu exposes Settings, Log, Wine config, Finder, and Remove (which forgets the entry, not the files).
struct ManualGameTileView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    let game: ManualGame
    let onSettings: () -> Void
    @State private var hovering = false
    @State private var confirmingRemove = false

    var body: some View {
        let lib = env.gameLibrary
        let running = lib.isRunning(game)
        let busy = lib.isBusy(game)

        VStack(alignment: .leading, spacing: 0) {
            ManualGameArtwork(exe: game.executablePath)
                .frame(maxWidth: .infinity, minHeight: 92, maxHeight: 92).clipped()

            VStack(alignment: .leading, spacing: 8) {
                Text(game.name).font(.headline).lineLimit(1)
                Text("Non-Steam game").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    primaryButton(running: running, busy: busy)
                    Spacer()
                    Menu { menuItems() } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
            }
            .padding()
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.tint.opacity(hovering ? 0.5 : 0), lineWidth: 1))
        .shadow(color: .black.opacity(hovering ? 0.22 : 0), radius: 9, y: 4)
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { onSettings() }
        .onHover { hovering = $0 }
        .help("Edit settings")
        .contextMenu { menuItems() }
        .confirmationDialog("Remove \(game.name)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await env.gameLibrary.removeManual(game) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes it from your library. The installed files on disk are left untouched.")
        }
    }

    @ViewBuilder
    private func primaryButton(running: Bool, busy: Bool) -> some View {
        let lib = env.gameLibrary
        if running {
            Button(role: .destructive) { Task { await lib.stopManual(game) } } label: {
                Label("Stop", systemImage: "stop.fill")
            }.buttonStyle(.borderedProminent).tint(.red)
        } else if busy {
            Button {} label: {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Launching…") }
            }.buttonStyle(.borderedProminent).disabled(true)
        } else {
            Button { Task { await lib.playManual(game) } } label: { Label("Play", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent).disabled(!lib.canLaunch)
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
                guard let app = env.makeManualGameShortcut(game) else { return }
                // Best-effort: stamp the game's icon on the bundle, then reveal it.
                if let icon = await ManualIconCache.shared.icon(for: game.executablePath) {
                    NSWorkspace.shared.setIcon(icon, forFile: app.path, options: [])
                }
                NSWorkspace.shared.activateFileViewerSelecting([app])
            }
        }
        .disabled(!env.gameLibrary.canLaunch)
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
