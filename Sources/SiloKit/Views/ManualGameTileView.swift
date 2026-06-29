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
            ZStack {
                GameArtworkPlaceholder()
                Image(systemName: "gamecontroller.fill")
                    .font(.largeTitle).foregroundStyle(.white.opacity(0.85))
            }
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
        Button("View in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([game.executablePath])
        }
        Divider()
        Button("Remove…", role: .destructive) { confirmingRemove = true }
    }
}
