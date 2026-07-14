import SwiftUI
import AppKit

/// Edit a manual (non-Steam) game: name, executable, its isolated bottle, performance flags, and launch
/// options. Saving persists the edited copy through the library view model.
struct ManualGameSettingsSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    /// A local editable copy — only written back on Save.
    @State var game: ManualGame

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $game.name)
                }

                Section("Executable") {
                    Text(game.executablePath.path)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Button("Change .exe…") {
                        if let exe = chooseExecutable(
                            message: "Choose the game's .exe.",
                            directory: game.executablePath.deletingLastPathComponent()) {
                            game.executablePath = exe
                        }
                    }
                }

                Section {
                    Button("Run Installer in this bottle…") {
                        if let installer = chooseExecutable(
                            message: "Choose a setup .exe or .msi to run in this game's bottle.",
                            installer: true) {
                            Task { await env.gameLibrary.runInstaller(installer, forBottle: game.bottleID) }
                        }
                    }
                    Button("Show bottle in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([env.paths.manualBottle(game.bottleID)])
                    }
                } header: {
                    Text("Bottle")
                } footer: {
                    Text("This game runs in its own isolated Wine prefix — install runtimes or patch it "
                         + "here without affecting other games.")
                }

                Section {
                    Picker("Graphics", selection: $game.graphics) {
                        ForEach(GraphicsChoice.allCases) { Text($0.displayName).tag($0) }
                    }
                    Text(game.graphics.recommendedFor)
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("Graphics Backend")
                } footer: {
                    Text("Automatic picks the backend per game — 32-bit games use DXMT, others use GPTK / "
                         + "D3DMetal. Using DXMT requires installing it in Settings → DXMT. Takes effect next launch.")
                }

                PerformanceFlagsSection(flags: $game.envFlags)
                LaunchOptionsSection(text: $game.launchOptionsString)
            }
            .formStyle(.grouped)
            .navigationTitle(game.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await env.gameLibrary.updateManual(game); dismiss() } }
                }
            }
        }
        .frame(width: 480, height: 560)
    }
}
