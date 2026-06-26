import SwiftUI

enum SidebarItem: Hashable {
    case library, backend, runtimes, about
}

struct RootView: View {
    @State private var selection: SidebarItem? = .library

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            switch selection ?? .library {
            case .library: LibraryGridView()
            case .backend: BackendSettingsView()
            case .runtimes: RuntimeManagerView()
            case .about: AboutView()
            }
        }
    }
}

struct SidebarView: View {
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Label("Library", systemImage: "square.grid.2x2").tag(SidebarItem.library)
            Label("Backend & Runtime", systemImage: "gearshape.2").tag(SidebarItem.backend)
            Label("Runtimes", systemImage: "arrow.down.circle").tag(SidebarItem.runtimes)
            Label("About", systemImage: "info.circle").tag(SidebarItem.about)
        }
        .navigationTitle(Silo.appName)
        .frame(minWidth: 200)
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox.fill").font(.system(size: 48)).foregroundStyle(.tint)
            Text(Silo.appName).font(.largeTitle.bold())
            Text("Version \(Silo.version)").foregroundStyle(.secondary)
            Text("Isolated Wine/GPTK launcher for Windows Steam games.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text("Silo never bundles or downloads Wine, GPTK, or any Steam-API emulator.")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .padding(40)
        .navigationTitle("About")
    }
}
