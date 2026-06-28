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
                DisclosureGroup("Advanced (manual paths)", isExpanded: $showAdvanced) {
                    PathPickerRow(title: "Wine binary (overrides Wine Manager default)",
                                  url: $vm.config.wineBinaryPath, chooseDirectories: false)
                    PathPickerRow(title: "GPTK / D3DMetal lib dir (overrides Wine Manager default)",
                                  url: $vm.config.gptkLibDirPath, chooseDirectories: true)
                }
            }

            steamBottleSection

            Section {
                Button("Save") { Task { await vm.save() } }
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .formStyle(.grouped)
    }

    /// Stand up a shared Steam bottle (real Windows Steam, signed into in-app) so Steamworks/DRM games run
    /// co-resident with a logged-in Steam client.
    @ViewBuilder private var steamBottleSection: some View {
        let bottle = env.steamBottleVM
        @Bindable var session = env.steamClientSession
        Section {
            Button("Set up Steam bottle") { Task { await bottle.setUp() } }
                .disabled(!bottle.canSetUp)
            Button("Launch Steam") { Task { await bottle.launchSteam() } }
                .disabled(bottle.busy || !bottle.steamInstalled)
            Toggle("Hardware-accelerated UI (experimental)", isOn: $session.hardwareAccelerated)
                .help("Render Steam's UI on the GPU (ANGLE→D3DMetal) instead of software. May show a "
                      + "black window — turn off if so. Games are GPU-accelerated either way.")
            Button("Reset Steam login") { Task { await bottle.resetLogin() } }
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
