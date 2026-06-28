import SwiftUI

enum SidebarItem: Hashable {
    case library, wine, about
}

struct RootView: View {
    @State private var selection: SidebarItem? = .library

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            switch selection ?? .library {
            case .library: LibraryGridView()
            case .wine: WineManagerView()
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
            Label("Wine Manager", systemImage: "wineglass").tag(SidebarItem.wine)
            Label("About", systemImage: "info.circle").tag(SidebarItem.about)
        }
        .navigationTitle(Silo.appName)
        .frame(minWidth: 200)
    }
}

struct AboutView: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox.fill").font(.system(size: 48)).foregroundStyle(.tint)
            Text(Silo.appName).font(.largeTitle.bold())
            Text("Version \(Silo.version)").foregroundStyle(.secondary)
            if let update = env.updateCheck, update.isNewer {
                updateSection(update)
            }
            Text("Isolated Wine/GPTK launcher for Windows Steam games.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text("Silo never bundles or downloads Wine, GPTK, or any Steam-API emulator.")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .padding(40)
        .navigationTitle("About")
    }

    /// Inline updater UI: one button downloads, self-replaces, and relaunches (no browser/manual install).
    @ViewBuilder private func updateSection(_ update: Updater.UpdateCheck) -> some View {
        VStack(spacing: 6) {
            Text("Update available: \(update.latestVersion)").font(.callout).foregroundStyle(.tint)
            switch env.updateState {
            case .idle:
                Button("Download & Relaunch") { Task { await env.installUpdate() } }
                    .buttonStyle(.borderedProminent)
            case .downloading:
                ProgressView("Downloading…").controlSize(.small)
            case .installing:
                ProgressView("Installing…").controlSize(.small)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                Button("Try Again") { Task { await env.installUpdate() } }
            }
        }
    }
}
