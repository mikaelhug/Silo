import SwiftUI
import AppKit

struct GameCardView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    let game: SteamApp
    let onSettings: () -> Void

    var body: some View {
        let busy = env.library.busyAppIDs.contains(game.appID)
        let running = env.library.isRunning(game)
        VStack(alignment: .leading, spacing: 0) {
            AsyncImage(url: game.headerArtURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .empty:
                    artPlaceholder.overlay(ProgressView().controlSize(.small))
                default:
                    artPlaceholder
                }
            }
            .frame(maxWidth: .infinity, minHeight: 92, maxHeight: 92)
            .clipped()

            VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(game.name).font(.headline).lineLimit(1)
                Spacer()
                InstallBadgeView(app: game)
            }
            Text(Self.byteString(game.sizeOnDisk))
                .font(.caption).foregroundStyle(.secondary)
            if let progress = game.downloadProgress {
                ProgressView(value: progress)
            }
            HStack {
                if running {
                    Button(role: .destructive) {
                        Task { await env.library.stop(game) }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                } else {
                    Button {
                        Task { await env.library.play(game) }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || !env.library.canLaunch)
                }

                Button("Isolate") { Task { await env.library.isolate(game) } }
                    .disabled(busy || running || !env.library.canLaunch)

                Spacer()

                if running {
                    Label("Running", systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.green)
                } else if busy {
                    ProgressView().controlSize(.small)
                }
                Menu { managementMenu() } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            }
            .padding()
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .help(env.library.canLaunch ? "" : "Configure a Wine backend to launch games.")
        .contextMenu {
            if running {
                Button("Stop", role: .destructive) { Task { await env.library.stop(game) } }
            } else {
                Button("Play") { Task { await env.library.play(game) } }
                    .disabled(busy || !env.library.canLaunch)
                Button("Isolate (Prepare Prefix)") { Task { await env.library.isolate(game) } }
                    .disabled(busy || !env.library.canLaunch)
            }
            Divider()
            managementMenu()
        }
    }

    /// Per-game management actions, shared by the ellipsis menu and the right-click context menu.
    @ViewBuilder
    private func managementMenu() -> some View {
        Button("Settings…", action: onSettings)
        Button("View Log…") {
            openWindow(id: "silo-log", value: LogTarget(title: "\(game.name) — Log", url: env.logURL(for: game)))
        }
        Divider()
        Button("Reveal Prefix in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([env.library.prefixURL(for: game)])
        }
        Button("Wine Config…") { Task { await env.library.openWinecfg(game) } }
            .disabled(!env.library.canLaunch)
        if let store = game.storePageURL {
            Button("View on Steam Store") { NSWorkspace.shared.open(store) }
        }
        Divider()
        Button("Reset Prefix", role: .destructive) {
            Task { await env.library.resetPrefix(game) }
        }
        .disabled(env.library.isRunning(game))
    }

    private var artPlaceholder: some View {
        LinearGradient(colors: [Color.indigo.opacity(0.55), Color.cyan.opacity(0.45)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(Image(systemName: "gamecontroller.fill").font(.title2).foregroundStyle(.white.opacity(0.7)))
    }

    static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct InstallBadgeView: View {
    let app: SteamApp

    var body: some View {
        let (text, color) = badge
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    private var badge: (String, Color) {
        if app.needsUpdate { return ("Update", .orange) }
        if app.isFullyInstalled { return ("Installed", .green) }
        if app.stateFlags.isDownloading { return ("Downloading", .blue) }
        return ("Not installed", .gray)
    }
}
