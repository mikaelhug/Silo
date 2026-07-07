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
                        if let vm { Task { if await vm.save() { dismiss() } } }
                    }
                }
            }
        }
        .frame(width: 480, height: 540)
        .task {
            vm = await env.makeGameSettings(appID: game.appID, backend: game.backend)
            // Off the main actor: a large game's install dir can hold tens of thousands of files and may
            // sit on a slow/external volume, and the exe scan is a full recursive walk — running it inline
            // would jank the sheet as it opens.
            let installURL = game.installURL
            executables = await Task.detached { ExecutableResolver.allExecutables(in: installURL) }.value
        }
    }

    @ViewBuilder
    private func form(_ model: GameSettingsViewModel) -> some View {
        @Bindable var vm = model
        Form {
            if let message = vm.errorMessage {
                Section { Text(message).foregroundStyle(.red) }
            }
            PerformanceFlagsSection(flags: $vm.config.envFlags)
            LaunchOptionsSection(text: $vm.config.launchOptionsString)

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
                    ForEach(SteamPresenceStrategy.allCases) { Text($0.displayName).tag($0) }
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
