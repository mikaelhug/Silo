import SwiftUI
import AppKit

struct GameCardView: View {
    @Environment(AppEnvironment.self) private var env
    let game: SteamApp
    let onSettings: () -> Void
    let onLog: () -> Void

    var body: some View {
        let busy = env.library.busyAppIDs.contains(game.appID)
        let running = env.library.isRunning(game)
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
                } else {
                    Menu {
                        Button("Settings…", action: onSettings)
                        Button("View Log…", action: onLog)
                        Divider()
                        Button("Reveal Prefix in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([env.library.prefixURL(for: game)])
                        }
                        Button("Wine Config…") { Task { await env.library.openWinecfg(game) } }
                            .disabled(!env.library.canLaunch)
                        Button("Reset Prefix", role: .destructive) {
                            Task { await env.library.resetPrefix(game) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .help(env.library.canLaunch ? "" : "Configure a Wine backend to launch games.")
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
