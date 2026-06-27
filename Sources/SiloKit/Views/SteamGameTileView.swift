import SwiftUI
import AppKit

/// A library tile for an owned Windows-only game (`SteamAppInfo`). Not installed → Download; installed
/// → Play/Stop. Right-click + ellipsis expose Settings, Log, prefix tools.
struct SteamGameTileView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    let game: SteamAppInfo
    let onSettings: () -> Void

    var body: some View {
        let lib = env.gameLibrary
        let installed = lib.isInstalled(game)
        let downloading = lib.isDownloading(game)
        let busy = lib.isBusy(game)
        let running = lib.isRunning(game)

        VStack(alignment: .leading, spacing: 0) {
            AsyncImage(url: headerArtURL) { phase in
                switch phase {
                case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                case .empty: artPlaceholder.overlay(ProgressView().controlSize(.small))
                default: artPlaceholder
                }
            }
            .frame(maxWidth: .infinity, minHeight: 92, maxHeight: 92).clipped()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(game.name).font(.headline).lineLimit(1)
                    Spacer()
                    badge(installed: installed, downloading: downloading)
                }
                if let size = lib.sizeString(game), installed {
                    Text(size).font(.caption).foregroundStyle(.secondary)
                }
                if downloading {
                    ProgressView(value: lib.downloadProgress(game) ?? 0) {
                        Text(lib.downloadProgress(game).map { "Downloading \(Int($0 * 100))%" } ?? "Downloading…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    if running {
                        Button(role: .destructive) { Task { await lib.stop(game) } } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }.buttonStyle(.borderedProminent).tint(.red)
                    } else if installed {
                        Button { Task { await lib.play(game) } } label: { Label("Play", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent).disabled(busy || !lib.canLaunch)
                    } else {
                        Button { Task { await lib.download(game) } } label: {
                            Label(downloading ? "Downloading…" : "Download", systemImage: "arrow.down.circle")
                        }.buttonStyle(.borderedProminent).disabled(busy || downloading)
                    }
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Menu { menuItems(installed: installed) } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
            }
            .padding()
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contextMenu { menuItems(installed: installed) }
    }

    @ViewBuilder private func badge(installed: Bool, downloading: Bool) -> some View {
        let (text, color): (String, Color) =
            downloading ? ("Downloading", .blue) : installed ? ("Installed", .green) : ("Owned", .gray)
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    @ViewBuilder private func menuItems(installed: Bool) -> some View {
        Button("Settings…", action: onSettings)
        Button("View Download/Run Log…") {
            openWindow(id: "silo-log", value: LogTarget(title: "\(game.name) — Log", url: env.logURL(forAppID: game.appID)))
        }
        if installed {
            Button("Update / Re-download") { Task { await env.gameLibrary.download(game) } }
            Button("Wine Config…") { Task { await env.gameLibrary.openWinecfg(game) } }
                .disabled(!env.gameLibrary.canLaunch)
            Button("Reveal Files in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([env.paths.gameInstallDir(forAppID: game.appID)])
            }
        }
        if let store = URL(string: "https://store.steampowered.com/app/\(game.appID)") {
            Button("View on Steam Store") { NSWorkspace.shared.open(store) }
        }
    }

    private var headerArtURL: URL? {
        URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(game.appID)/header.jpg")
    }
    private var artPlaceholder: some View {
        LinearGradient(colors: [Color.indigo.opacity(0.55), Color.cyan.opacity(0.45)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(Image(systemName: "gamecontroller.fill").font(.title2).foregroundStyle(.white.opacity(0.7)))
    }
}
