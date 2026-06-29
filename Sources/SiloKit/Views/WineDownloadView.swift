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

            Section("Installed Wine") {
                if vm.installed.isEmpty {
                    Text("None installed.").foregroundStyle(.secondary)
                } else {
                    ForEach(vm.installed) { wine in
                        RuntimeInstallRow(
                            title: wine.displayName,
                            warning: wine.isUsable ? nil : "no wine binary found",
                            subtitle: nil,
                            isDefault: vm.isDefault(wine),
                            canSetDefault: wine.isUsable,
                            onSetDefault: { vm.setDefault(wine) },
                            onRemove: { Task { await vm.remove(wine) } })
                    }
                }
            }

            if let message = vm.statusMessage {
                Section { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .task { await vm.refresh() }
    }
}
