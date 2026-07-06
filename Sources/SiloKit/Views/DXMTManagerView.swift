import SwiftUI

/// The "DXMT" tab: the optional older-games backend (DirectX 10/11 titles GPTK can't run). A runtime tab
/// that mirrors the Wine tab — install the latest build from GitHub, then pick the default from the
/// installed list. Its Steam bottle lives in Settings → General alongside the GPTK one.
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
                if vm.isInstalling { ProgressView().controlSize(.small) }
            } header: {
                Text("DXMT runtime")
            }

            RuntimeInstalledSection(title: "Installed DXMT", vm: vm)

            if let message = vm.statusMessage {
                Section { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .task { await vm.refresh() }
    }
}
