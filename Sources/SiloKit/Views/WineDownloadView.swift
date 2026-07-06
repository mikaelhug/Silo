import SwiftUI

/// The "Wine" tab: install the latest prebuilt Wine (from Silo's CI releases) and manage installs.
struct WineDownloadView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var vm = env.runtime
        Form {
            Section {
                Button {
                    Task { await vm.installLatest() }
                } label: {
                    Label("Install latest Wine", systemImage: "arrow.down.circle")
                }
                .disabled(vm.isInstalling)
                if vm.isInstalling { ProgressView().controlSize(.small) }
            } header: {
                Text("Wine")
            }

            RuntimeInstalledSection(title: "Installed Wine", vm: vm)

            if let message = vm.statusMessage {
                Section { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .task { await vm.refresh() }
    }
}
