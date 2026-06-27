import SwiftUI
import AppKit

/// A library tile for an owned Windows-only game (`SteamAppInfo`). Not installed → Download; installed
/// → Play/Stop. Right-click + ellipsis expose Settings, Log, prefix tools.
struct SteamGameTileView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    let game: SteamAppInfo
    let onSettings: () -> Void
    let onDetails: () -> Void
    @State private var hovering = false

    var body: some View {
        let lib = env.gameLibrary
        let installed = lib.isInstalled(game)
        let downloading = lib.isDownloading(game)
        let paused = lib.isPaused(game)
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
            .contentShape(Rectangle())
            .onTapGesture { onDetails() }

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
                        Text(downloadLine).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                } else if paused {
                    Text("Download paused — \(Int((lib.downloadProgress(game) ?? 0) * 100))% done")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack(spacing: 8) {
                    primaryButton(running: running, busy: busy, installed: installed,
                                  downloading: downloading, paused: paused)
                    if downloading {
                        Button { Task { await lib.pause(game) } } label: { Image(systemName: "pause.circle.fill") }
                            .buttonStyle(.borderless).help("Pause download")
                    }
                    if downloading || paused {
                        Button { Task { await lib.cancel(game) } } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Cancel download")
                    }
                    Spacer()
                    Menu { menuItems(installed: installed) } label: { Image(systemName: "ellipsis.circle") }
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
        .onHover { hovering = $0 }
        .contextMenu { menuItems(installed: installed) }
    }

    /// Progress · speed · ETA line shown while downloading.
    private var downloadLine: String {
        let lib = env.gameLibrary
        var parts: [String] = []
        parts.append(lib.downloadProgress(game).map { "\(Int($0 * 100))%" } ?? "Starting…")
        if let speed = lib.speedString(game) { parts.append(speed) }
        if let eta = lib.etaString(game) { parts.append("\(eta) left") }
        return parts.joined(separator: " · ")
    }

    /// The main action button — context-aware so Play never looks frozen while a game is launching.
    @ViewBuilder
    private func primaryButton(running: Bool, busy: Bool, installed: Bool, downloading: Bool, paused: Bool) -> some View {
        let lib = env.gameLibrary
        if running {
            Button(role: .destructive) { Task { await lib.stop(game) } } label: {
                Label("Stop", systemImage: "stop.fill")
            }.buttonStyle(.borderedProminent).tint(.red)
        } else if downloading {
            Button {} label: { Label("Downloading…", systemImage: "arrow.down.circle") }
                .buttonStyle(.bordered).disabled(true)
        } else if busy {
            Button {} label: {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Launching…") }
            }.buttonStyle(.borderedProminent).disabled(true)
        } else if installed {
            Button { Task { await lib.play(game) } } label: { Label("Play", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent).disabled(!lib.canLaunch)
        } else if paused {
            Button { Task { await lib.download(game) } } label: { Label("Resume", systemImage: "play.circle") }
                .buttonStyle(.borderedProminent)
        } else {
            Button { Task { await lib.download(game) } } label: { Label("Download", systemImage: "arrow.down.circle") }
                .buttonStyle(.borderedProminent)
        }
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
        Button("Details…", action: onDetails)
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
