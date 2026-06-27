import SwiftUI

struct GameSettingsSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let game: SteamApp
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
            .navigationTitle(game.name)
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
            vm = await env.makeGameSettings(for: game)
            executables = ExecutableResolver.allExecutables(in: game.installURL)
        }
    }

    @ViewBuilder
    private func form(_ model: GameSettingsViewModel) -> some View {
        @Bindable var vm = model
        Form {
            Section("Graphics backend") {
                Picker("Backend", selection: $vm.config.backend) {
                    ForEach(GraphicsBackend.allCases) { Text($0.displayName).tag($0) }
                }
            }

            Section("Environment") {
                Toggle("ESYNC", isOn: $vm.config.envFlags.esync)
                Toggle("MSYNC (Apple Silicon)", isOn: $vm.config.envFlags.msync)
                Toggle("Metal HUD", isOn: $vm.config.envFlags.metalHUD)
                if vm.config.backend == .crossover {
                    TextField("DXVK HUD (e.g. fps,memory)", text: Binding(
                        get: { vm.config.envFlags.dxvkHUD ?? "" },
                        set: { vm.config.envFlags.dxvkHUD = $0.isEmpty ? nil : $0 }))
                }
            }

            Section("Launch options") {
                TextField("e.g. -windowed -dx11 -novid", text: $vm.config.launchOptionsString)
                    .autocorrectionDisabled()
                Text("Extra arguments passed to the game executable (space-separated).")
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

            Section("Steam presence") {
                Picker("Strategy", selection: $vm.config.presence) {
                    ForEach(SteamPresenceStrategy.allCases) { Text($0.displayName).tag($0) }
                }
                if vm.config.presence == .emulatorStub {
                    PathPickerRow(title: "Emulator stub (e.g. steam_api64.dll)",
                                  url: $vm.config.steamStubSourcePath, chooseDirectories: false)
                    Text("Owned games only. You are responsible for compliance with Steam's "
                         + "Subscriber Agreement. Silo never downloads this file.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
