import SwiftUI

/// The "DXMT" tab: the optional older-games backend (DirectX 10/11 titles GPTK can't run). Download or
/// import its runtime and set up its own Steam bottle — a runtime tab like Wine and GPTK.
struct DXMTManagerView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Form {
            Section {
                Button {
                    Task { await env.downloadLatestDXMT() }
                } label: {
                    Label("Install latest DXMT", systemImage: "arrow.down.circle")
                }
                .disabled(env.dxmtDownloading)
                Button {
                    if let dir = chooseDirectory(message: "Choose the DXMT x86_64-windows module folder.") {
                        Task { await env.importDXMTRuntime(from: dir) }
                    }
                } label: {
                    Label("Import folder…", systemImage: "externaldrive.badge.plus")
                }
                .disabled(env.dxmtDownloading)
                if env.dxmtDownloading { ProgressView().controlSize(.small) }
            } header: {
                Text("DXMT runtime")
            } footer: {
                Text("For DirectX 10/11 titles GPTK can't run.")
            }

            Section("Installed") {
                Text(env.dxmtReady ? (env.backendSettings.config.dxmtRuntimeName ?? "Installed") : "None installed.")
                    .foregroundStyle(.secondary)
            }

            Section("Steam bottle") {
                SteamBottleControls(
                    bottle: env.dxmtBottleVM, noun: "DXMT Steam",
                    logButtonTitle: "Open bottle log",
                    logWindowTitle: "DXMT Steam Bottle — Log", logURL: env.paths.steamBottleLog(.dxmt))
                LabeledContent("Repair") {
                    HStack(spacing: 8) {
                        Button("Wine Config") { Task { await env.openWineTool("winecfg", for: .dxmt) } }
                        Button("Registry") { Task { await env.openWineTool("regedit", for: .dxmt) } }
                        Button("Control Panel") { Task { await env.openWineTool("control", for: .dxmt) } }
                    }
                    .disabled(env.wineBinary == nil || !env.dxmtSteamReady)
                }
            }

            if let message = env.backendSettings.statusMessage {
                Section { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }
}
