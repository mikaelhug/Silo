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
            } footer: {
                Text("Downloads the latest Wine build from Silo's releases (CrossOver-based, ~250 MB) "
                     + "and verifies its checksum.")
                    .font(.caption)
            }

            Section("Installed Wine") {
                if vm.installed.isEmpty {
                    Text("None installed.").foregroundStyle(.secondary)
                } else {
                    ForEach(vm.installed) { wine in
                        HStack(spacing: 10) {
                            Image(systemName: vm.isDefault(wine) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(vm.isDefault(wine) ? Color.green : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(wine.displayName)
                                if !wine.isUsable {
                                    Text("no wine binary found").font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            if vm.isDefault(wine) {
                                Text("Default").font(.caption2).foregroundStyle(.green)
                            } else {
                                Button("Set default") { vm.setDefault(wine) }.disabled(!wine.isUsable)
                            }
                            Button(role: .destructive) {
                                Task { await vm.remove(wine) }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
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
