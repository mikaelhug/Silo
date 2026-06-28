import SwiftUI

struct GPTKManagerView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var vm = env.gptkManager
        Form {
            Section {
                Button {
                    if let dmg = chooseDiskImage() { Task { await vm.importGPTK(from: dmg) } }
                } label: {
                    Label("Import GPTK from Apple .dmg…", systemImage: "externaldrive.badge.plus")
                }
                .disabled(vm.isImporting)
                if vm.isImporting { ProgressView().controlSize(.small) }
                Link("Download GPTK from Apple (requires Apple ID)", destination: Silo.appleGPTKURL)
                    .font(.caption)
            } header: {
                Text("Game Porting Toolkit")
            } footer: {
                Text("Silo mounts the .dmg and extracts the D3DMetal libraries. A wine binary is still "
                     + "needed (set it in Backend & Runtime).")
                    .font(.caption)
            }

            Section("Installed versions") {
                if vm.installs.isEmpty {
                    Text("No GPTK versions imported yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(vm.installs) { install in
                        RuntimeInstallRow(
                            title: install.displayName,
                            warning: nil,
                            subtitle: install.installDir.path,
                            isDefault: vm.isDefault(install),
                            canSetDefault: true,
                            onSetDefault: { vm.setDefault(install) },
                            onRemove: { Task { await vm.remove(install) } })
                    }
                }
            }

            if let message = vm.statusMessage {
                Section { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .task { vm.refresh() }
    }
}
