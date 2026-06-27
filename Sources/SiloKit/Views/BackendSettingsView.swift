import SwiftUI

struct BackendSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showAdvanced = false

    var body: some View {
        @Bindable var vm = env.backendSettings
        Form {
            Section("Status") {
                LabeledContent("Ready to launch", value: vm.isConfigured ? "Yes" : "Not yet")
                LabeledContent("Default Wine", value: vm.config.wineRuntimeName ?? "none — add in Wine Manager")
                LabeledContent("Default GPTK", value: vm.config.gptkRuntimeName ?? "none — add in Wine Manager")
                if let message = vm.statusMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Steam account", value: vm.config.steamUsername ?? "not signed in")
            } header: {
                Text("Steam")
            } footer: {
                Text("Games are downloaded headlessly via SteamCMD (native, no Wine). Sign in from the "
                     + "Library toolbar. Only your Windows-only games are listed.")
                    .font(.caption)
            }

            Section {
                DisclosureGroup("Advanced (manual paths)", isExpanded: $showAdvanced) {
                    Button("Auto-detect installed backend (Whisky / CrossOver)") { vm.autodetect() }
                    LabeledContent("Detected source", value: vm.config.detectedSource.rawValue)
                    PathPickerRow(title: "Wine binary (overrides Wine Manager default)",
                                  url: $vm.config.wineBinaryPath, chooseDirectories: false)
                    PathPickerRow(title: "CrossOver wine (fallback)",
                                  url: $vm.config.crossoverWinePath, chooseDirectories: false)
                    PathPickerRow(title: "GPTK / D3DMetal lib dir (overrides Wine Manager default)",
                                  url: $vm.config.gptkLibDirPath, chooseDirectories: true)
                    PathPickerRow(title: "DXVK DLL dir",
                                  url: $vm.config.dxvkDLLDirPath, chooseDirectories: true)
                }
            }

            Section {
                Button("Save") { Task { await vm.save() } }
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Advanced Settings")
    }
}
