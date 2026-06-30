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
    @State private var hovering = false
    @State private var confirmingUninstall = false

    var body: some View {
        let lib = env.gameLibrary
        let running = lib.isRunning(game)
        let busy = lib.isBusy(game)

        VStack(alignment: .leading, spacing: 0) {
            AsyncImage(url: game.headerArtURL) { phase in
                switch phase {
                case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                default: GameArtworkPlaceholder()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 92, maxHeight: 92).clipped()

            VStack(alignment: .leading, spacing: 8) {
                Text(game.name).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    if let size = lib.sizeString(game) {
                        Text(size).font(.caption).foregroundStyle(.secondary)
                    }
                    BackendTag(backend: game.backend)
                }
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
        .onTapGesture { onDetails() }
        .onHover { hovering = $0 }
        .help("Show details")
        .contextMenu { menuItems() }
        .uninstallConfirmation(game: game, isPresented: $confirmingUninstall, library: env.gameLibrary)
    }

    @ViewBuilder
    private func primaryButton(running: Bool, busy: Bool) -> some View {
        let lib = env.gameLibrary
        if running {
            Button(role: .destructive) { Task { await lib.stop(game) } } label: {
                Label("Stop", systemImage: "stop.fill")
            }.buttonStyle(.borderedProminent).tint(.red)
        } else if busy {
            Button {} label: {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Launching…") }
            }.buttonStyle(.borderedProminent).disabled(true)
        } else {
            Button { Task { await lib.play(game) } } label: { Label("Play", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent).disabled(!lib.canLaunch)
        }
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
