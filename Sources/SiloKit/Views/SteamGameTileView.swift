import SwiftUI
import AppKit

/// A library tile for a game installed in the Steam bottle (`SteamApp`). Play launches it co-resident
/// with the bottle's Steam client; the menu exposes Settings, Log, Wine config, Finder, Uninstall.
struct SteamGameTileView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    let game: SteamApp
    let onSettings: () -> Void
    let onDetails: () -> Void
    @State private var confirmingUninstall = false

    var body: some View {
        let lib = env.gameLibrary
        GameTileCard(
            title: game.name,
            isRunning: lib.isRunning(game), isBusy: lib.isBusy(game), canLaunch: lib.canLaunch,
            helpText: "Show details",
            onPlay: { Task { await lib.play(game) } },
            onStop: { Task { await lib.stop(game) } },
            onTap: onDetails
        ) {
            AsyncImage(url: game.headerArtURL) { phase in
                switch phase {
                case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                default: GameArtworkPlaceholder()
                }
            }
        } subtitle: {
            if let size = lib.sizeString(game) {
                Text(size).font(.caption).foregroundStyle(.secondary)
            }
            BackendTag(backend: game.backend)
        } menuItems: {
            menuItems()
        }
        .uninstallConfirmation(game: game, isPresented: $confirmingUninstall, library: env.gameLibrary)
    }

    @ViewBuilder private func menuItems() -> some View {
        Button("Details…", action: onDetails)
        Button("Settings…", action: onSettings)
        Button("View Log") {
            openWindow(id: LogTarget.windowID,
                       value: LogTarget(title: "\(game.name) — Log", url: env.logURL(forAppID: game.appID)))
        }
        Button("Wine Config…") { Task { await env.gameLibrary.openWinecfg(game.backend) } }
            .disabled(!env.gameLibrary.canLaunch)
        Button("View in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([game.installURL])
        }
        if let store = game.storePageURL {
            Button("View on Steam Store") { NSWorkspace.shared.open(store) }
        }
        Divider()
        Button("Uninstall…", role: .destructive) { confirmingUninstall = true }
    }
}
