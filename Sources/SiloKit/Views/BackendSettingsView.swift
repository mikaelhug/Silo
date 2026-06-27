import SwiftUI

struct BackendSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
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

            steamBottleSection

            Section {
                Button("Save") { Task { await vm.save() } }
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Advanced Settings")
    }

    /// Experimental: stand up a shared Steam bottle (real Windows Steam, login seeded from macOS Steam)
    /// for Steamworks/DRM games. This is the validation surface for the in-prefix-Steam approach.
    @ViewBuilder private var steamBottleSection: some View {
        let bottle = env.steamBottleVM
        Section {
            Button("Set up Steam bottle") { Task { await bottle.setUp() } }
                .disabled(!bottle.canSetUp)
            Button("Launch Steam") { Task { await bottle.launchSteam() } }
                .disabled(bottle.busy || !bottle.steamInstalled)
            Button("Open bottle log") {
                openWindow(id: LogTarget.windowID,
                           value: LogTarget(title: "Steam Bottle — Log", url: env.paths.steamBottleLog))
            }
            if bottle.busy { ProgressView().controlSize(.small) }
            if !bottle.status.isEmpty {
                Text(bottle.status).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Steam bottle (experimental)")
        } footer: {
            Text("For Steamworks/DRM games that need a running Steam client. “Set up” installs Windows "
                 + "Steam into a shared prefix; “Launch Steam” starts it — sign in once (it caches the "
                 + "login), then run a game and it shares this prefix. Requires a Steam-capable Wine build.")
                .font(.caption)
        }
    }
}
