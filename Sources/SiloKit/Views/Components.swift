import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Present an open panel for choosing a `.dmg` (GPTK). Returns nil if cancelled.
@MainActor
func chooseDiskImage() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.diskImage]
    return panel.runModal() == .OK ? panel.url : nil
}

/// Gradient fallback shown while a game's cover art loads or is unavailable (tile + detail hero).
struct GameArtworkPlaceholder: View {
    var iconFont: Font = .title2
    var body: some View {
        LinearGradient(colors: [.indigo.opacity(0.55), .cyan.opacity(0.45)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(Image(systemName: "gamecontroller.fill").font(iconFont).foregroundStyle(.white.opacity(0.7)))
    }
}

extension View {
    /// The shared "Uninstall this game?" confirmation used by both the tile and the detail view.
    func uninstallConfirmation(
        game: SteamAppInfo, isPresented: Binding<Bool>, library: GameLibraryViewModel
    ) -> some View {
        confirmationDialog("Uninstall \(game.name)?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) { Task { await library.uninstall(game) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes the game's files and its isolated Wine prefix (its settings and any local "
                 + "saves). You can re-download it anytime.")
        }
    }
}

/// A row that displays a path and lets the user pick a file or directory via NSOpenPanel
/// (powerbox grant — avoids TCC denials for non-sandboxed access).
struct PathPickerRow: View {
    let title: String
    @Binding var url: URL?
    var chooseDirectories: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(url?.path ?? "Not set")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Choose…", action: pick)
            if url != nil {
                Button(role: .destructive) { url = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = chooseDirectories
        panel.canChooseFiles = !chooseDirectories
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        if panel.runModal() == .OK { url = panel.url }
    }
}
