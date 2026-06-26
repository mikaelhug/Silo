import SwiftUI

struct BackendSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var vm = env.backendSettings
        Form {
            Section("Status") {
                LabeledContent("Detected source", value: vm.config.detectedSource.rawValue)
                LabeledContent("Ready to launch", value: vm.isConfigured ? "Yes" : "No")
                Button("Auto-detect backend") { vm.autodetect() }
                if let message = vm.statusMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            }

            Section("Master Steam bottle") {
                PathPickerRow(title: "Bottle folder (parent of drive_c)",
                              url: $vm.config.masterBottlePath, chooseDirectories: true)
                Button {
                    Task { await vm.installSteamBottle() }
                } label: {
                    Label("Create Master Steam Bottle (1-click)", systemImage: "shippingbox")
                }
                .disabled(vm.isInstallingBottle)
                if vm.isInstallingBottle { ProgressView().controlSize(.small) }
                Text("Boots a simple Wine bottle and silently installs the Steam client. "
                     + "Afterwards, open Steam, log in, and download games.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Wine / GPTK") {
                PathPickerRow(title: "Wine binary — GPTK (primary)",
                              url: $vm.config.wineBinaryPath, chooseDirectories: false)
                PathPickerRow(title: "CrossOver wine (fallback)",
                              url: $vm.config.crossoverWinePath, chooseDirectories: false)
                PathPickerRow(title: "Steam-bottle wine (vanilla; optional)",
                              url: $vm.config.steamWineBinaryPath, chooseDirectories: false)
                PathPickerRow(title: "GPTK / D3DMetal lib dir",
                              url: $vm.config.gptkLibDirPath, chooseDirectories: true)
                PathPickerRow(title: "DXVK DLL dir",
                              url: $vm.config.dxvkDLLDirPath, chooseDirectories: true)
            }

            Section {
                Button("Save") { Task { await vm.save() } }
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Backend & Runtime")
    }
}
