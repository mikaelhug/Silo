import SwiftUI
import AppKit

/// Edit a manual (non-Steam) game: name, executable, its isolated bottle, performance flags, and launch
/// options. Saving persists the edited copy through the library view model.
struct ManualGameSettingsSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    /// A local editable copy — only written back on Save.
    @State var game: ManualGame
    /// Edited as free text (seeded on appear); parsed into `envFlags.extra` on Save so it isn't
    /// re-normalized under the cursor while typing.
    @State private var envText = ""

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
                            message: "Choose a setup .exe to run in this game's bottle.") {
                            Task { await env.gameLibrary.runInstaller(installer, forBottle: game.id) }
                        }
                    }
                    Button("Show bottle in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([env.paths.manualBottle(game.id)])
                    }
                } header: {
                    Text("Bottle")
                } footer: {
                    Text("This game runs in its own isolated Wine prefix — install runtimes or patch it "
                         + "here without affecting other games.")
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

                Section {
                    TextField("KEY=VALUE (one per line)", text: $envText, axis: .vertical)
                        .lineLimit(2...6)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Environment variables")
                } footer: {
                    Text("Per-game env vars. For an ANGLE/Electron game that fails with shader / D3D11 "
                         + "errors, try ANGLE_DEFAULT_PLATFORM=opengl (or swiftshader) to steer it off the "
                         + "unsupported D3D11 backend.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(game.name)
            .onAppear { envText = game.envFlags.extraEnvironmentString }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        game.envFlags.extraEnvironmentString = envText
                        Task { await env.gameLibrary.updateManual(game); dismiss() }
                    }
                }
            }
        }
        .frame(width: 480, height: 600)
    }
}
