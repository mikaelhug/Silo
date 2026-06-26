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
                        HStack(spacing: 10) {
                            Image(systemName: vm.isDefault(install) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(vm.isDefault(install) ? Color.green : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(install.displayName)
                                Text(install.installDir.path)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if vm.isDefault(install) {
                                Text("Default").font(.caption2).foregroundStyle(.green)
                            } else {
                                Button("Set default") { vm.setDefault(install) }
                            }
                            Button(role: .destructive) {
                                Task { await vm.remove(install) }
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
        .task { vm.refresh() }
    }
}
