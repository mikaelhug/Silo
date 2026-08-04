import SwiftUI

/// The "DXVK" tab: the DirectX 9 + broad-compatibility Vulkan backend (D3D9/10/11 → Vulkan → the runtime's
/// bundled MoltenVK → Metal). A runtime tab that mirrors the Wine/DXMT tabs — install the latest build from
/// GitHub, then pick the default. Enables the DXVK graphics backend (the only one that runs DirectX 9).
struct DXVKManagerView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var vm = env.dxvkRuntime
        Form {
            Section {
                Button {
                    Task { await vm.installLatest() }
                } label: {
                    Label("Install latest DXVK", systemImage: "arrow.down.circle")
                }
                .disabled(vm.isInstalling)
                if vm.isInstalling { ProgressView().controlSize(.small) }
            } header: {
                Text("DXVK runtime")
            }

            RuntimeInstalledSection(title: "Installed DXVK", vm: vm)

            if let message = vm.statusMessage {
                Section { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .task { await vm.refresh() }
    }
}
