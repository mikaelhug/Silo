import SwiftUI

struct RuntimeManagerView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var vm = env.runtime
        Form {
            Section("Installed runtimes") {
                if vm.installed.isEmpty {
                    Text("None installed").foregroundStyle(.secondary)
                } else {
                    ForEach(vm.installed) { runtime in
                        HStack {
                            LabeledContent(runtime.name, value: runtime.kind.rawValue)
                            Spacer()
                            Button(role: .destructive) {
                                Task { await vm.remove(runtime) }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Section("Download a runtime") {
                TextField("GitHub repo (owner/name)", text: $vm.repo)
                Button("Fetch latest release") { Task { await vm.fetchAvailable() } }
                ForEach(vm.available, id: \.name) { asset in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(asset.name)
                            Text(Self.byteString(asset.size)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Install") { Task { await vm.install(asset) } }.disabled(vm.isBusy)
                    }
                }
            }

            if let message = vm.statusMessage {
                Section { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Runtimes")
        .task { await vm.refreshInstalled() }
    }

    static func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
