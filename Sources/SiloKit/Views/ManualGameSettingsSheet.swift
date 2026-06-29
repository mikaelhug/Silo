import SwiftUI

/// Edit a manual (non-Steam) game: name, executable, performance flags, and launch options. Saving
/// persists the edited copy through the library view model.
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

                Section("Performance") {
                    Picker("Sync", selection: $game.envFlags.syncMode) {
                        ForEach(SyncMode.allCases) { Text($0.displayName).tag($0) }
                    }
                    Toggle("Advertise AVX (Rosetta)", isOn: $game.envFlags.advertiseAVX)
                    Toggle("Performance HUD (FPS / frame time)", isOn: $game.envFlags.metalHUD)
                    Toggle("MetalFX upscaling", isOn: $game.envFlags.metalFX)
                    Toggle("DirectX Raytracing (M3+)", isOn: $game.envFlags.dxr)
                }

                Section("Launch options") {
                    TextField("e.g. -windowed -dx11", text: $game.launchOptionsString)
                        .autocorrectionDisabled()
                }
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
