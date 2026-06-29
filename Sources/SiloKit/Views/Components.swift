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

/// Present an open panel for choosing a Windows `.exe` (a game or installer). `directory` sets the initial
/// location (e.g. the bottle's `drive_c`). Returns nil if cancelled.
@MainActor
func chooseExecutable(message: String, directory: URL? = nil) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = message
    panel.prompt = "Choose"
    if let exe = UTType(filenameExtension: "exe") { panel.allowedContentTypes = [exe] }
    if let directory, FileManager.default.fileExists(atPath: directory.path) {
        panel.directoryURL = directory
    }
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
        game: SteamApp, isPresented: Binding<Bool>, library: GameLibraryViewModel
    ) -> some View {
        confirmationDialog("Uninstall \(game.name)?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) { Task { await library.uninstall(game) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Asks the bottle's Steam to uninstall this game. You can reinstall it anytime.")
        }
    }
}
