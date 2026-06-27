import SwiftUI

struct GameSettingsSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let appID: Int
    let name: String
    @State private var vm: GameSettingsViewModel?
    @State private var executables: [String] = []

    var body: some View {
        NavigationStack {
            Group {
                if let vm {
                    form(vm)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let vm { Task { await vm.save(); dismiss() } }
                    }
                }
            }
        }
        .frame(width: 480, height: 540)
        .task {
            vm = await env.makeGameSettings(appID: appID, name: name)
            executables = ExecutableResolver.allExecutables(in: env.gameInstallDir(forAppID: appID))
        }
    }

    @ViewBuilder
    private func form(_ model: GameSettingsViewModel) -> some View {
        @Bindable var vm = model
        Form {
            Section {
                Picker("Backend", selection: $vm.config.backend) {
                    ForEach(GraphicsBackend.allCases) { Text($0.displayName).tag($0) }
                }
            } header: {
                Text("Graphics backend")
            } footer: {
                Text("Game Porting Toolkit (D3DMetal) is the default — it translates DirectX 9–12 (incl. "
                     + "ray tracing) and is the most capable on Apple Silicon. Switch to CrossOver (DXVK) "
                     + "only if a game misbehaves under GPTK; Silo also falls back to it automatically when "
                     + "GPTK isn't installed.")
            }

            Section {
                Picker("Sync", selection: $vm.config.envFlags.syncMode) {
                    ForEach(SyncMode.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Advertise AVX (Rosetta)", isOn: $vm.config.envFlags.advertiseAVX)
                Toggle("Performance HUD (FPS / frame time)", isOn: $vm.config.envFlags.metalHUD)
                if vm.config.backend == .gptk {
                    Toggle("MetalFX upscaling", isOn: $vm.config.envFlags.metalFX)
                    Toggle("DirectX Raytracing (M3+)", isOn: $vm.config.envFlags.dxr)
                }
                if vm.config.backend == .crossover {
                    TextField("DXVK HUD (e.g. fps,memory)", text: Binding(
                        get: { vm.config.envFlags.dxvkHUD ?? "" },
                        set: { vm.config.envFlags.dxvkHUD = $0.isEmpty ? nil : $0 }))
                }
            } header: {
                Text("Performance")
            } footer: {
                Text("MSync + advertise-AVX is the recommended Apple-Silicon baseline. The Performance "
                     + "HUD overlays live FPS/frame time on the game. MetalFX upscales for more FPS; "
                     + "Raytracing needs an M3 or newer.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("e.g. -windowed -dx11 -novid", text: $vm.config.launchOptionsString)
                    .autocorrectionDisabled()
            } header: {
                Text("Launch options")
            } footer: {
                Text("Extra arguments passed to the game executable (space-separated). Electron/Chromium "
                     + "games that fail with “Could not create D3D11 device” / “No available renderers”: "
                     + "try --use-angle=gl, then --disable-gpu --in-process-gpu.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Executable") {
                if executables.isEmpty {
                    TextField("Relative path (blank = auto-detect)", text: Binding(
                        get: { vm.config.executableRelativePath ?? "" },
                        set: { vm.config.executableRelativePath = $0.isEmpty ? nil : $0 }))
                } else {
                    Picker("Executable", selection: Binding(
                        get: { vm.config.executableRelativePath ?? "" },
                        set: { vm.config.executableRelativePath = $0.isEmpty ? nil : $0 })) {
                        Text("Auto-detect").tag("")
                        ForEach(executables, id: \.self) { Text($0).tag($0) }
                    }
                }
            }

            Section {
                Picker("Strategy", selection: $vm.config.presence) {
                    ForEach(SteamPresenceStrategy.userSelectable) { Text($0.displayName).tag($0) }
                }
            } header: {
                Text("Steam presence")
            } footer: {
                Text("steam_appid.txt is enough for most games. Titles that hard-require the Steam client "
                     + "(they quit with “Steam not initialized”) aren't supported yet — running a real "
                     + "Steam client in the prefix is planned.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
