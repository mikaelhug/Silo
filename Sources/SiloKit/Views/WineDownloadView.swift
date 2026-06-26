import SwiftUI

/// The "Wine" tab: lists the latest prebuilt Wine versions for one-click install (Heroic-style),
/// plus installed Wine builds with set-default / remove.
struct WineDownloadView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var vm = env.runtime
        Form {
            Section {
                Button {
                    Task { await vm.fetchLatest() }
                } label: {
                    Label("Refresh list", systemImage: "arrow.clockwise")
                }
                if vm.latest.isEmpty {
                    Text("Tap Refresh to list the latest Wine versions.").foregroundStyle(.secondary)
                }
                ForEach(vm.latest, id: \.tagName) { release in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(release.version)
                            if let asset = RuntimeManager.preferredAsset(release) {
                                Text(Self.byteString(asset.size)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if vm.isInstalled(release) {
                            Text("Installed").font(.caption).foregroundStyle(.green)
                        } else if vm.busyTag == release.tagName {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Install") { Task { await vm.install(release) } }
                                .disabled(vm.isInstalling)
                        }
                    }
                }
            } header: {
                Text("Latest Wine versions")
            } footer: {
                Text("Prebuilt GPTK-patched Wine. Downloads are large (~250 MB).").font(.caption)
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
        .task {
            await vm.refresh()
            if vm.latest.isEmpty { await vm.fetchLatest() }
        }
    }

    static func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
