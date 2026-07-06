import SwiftUI

/// The "DXMT" tab: the optional older-games backend (DirectX 10/11 titles GPTK can't run). A runtime tab
/// that mirrors the Wine tab — install the latest build from GitHub (or import a folder), then pick the
/// default from the installed list. Its Steam bottle lives in Settings → General alongside the GPTK one.
struct DXMTManagerView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var vm = env.dxmtRuntime
        Form {
            Section {
                Button {
                    Task { await vm.installLatest() }
                } label: {
                    Label("Install latest DXMT", systemImage: "arrow.down.circle")
                }
                .disabled(vm.isInstalling)
                Button {
                    if let dir = chooseDirectory(message: "Choose the DXMT x86_64-windows module folder.") {
                        Task { await env.importDXMTRuntime(from: dir) }
                    }
                } label: {
                    Label("Import folder…", systemImage: "externaldrive.badge.plus")
                }
                .disabled(vm.isInstalling)
                if vm.isInstalling { ProgressView().controlSize(.small) }
            } header: {
                Text("DXMT runtime")
            } footer: {
                Text("For DirectX 10/11 titles GPTK can't run.")
            }

            RuntimeInstalledSection(title: "Installed DXMT", vm: vm)

            // The backend adopts a DXMT via `applyDXMTLibDir`, so a folder import (which lives outside the
            // Runtimes dir and isn't in the list) is still surfaced as the active runtime here.
            if let active = env.backendSettings.config.dxmtRuntimeName,
               !vm.installed.contains(where: { $0.name == active }) {
                Section("Active") {
                    Text(active).foregroundStyle(.secondary)
                }
            }

            if let message = vm.statusMessage ?? env.backendSettings.statusMessage {
                Section { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .task { await vm.refresh() }
    }
}
