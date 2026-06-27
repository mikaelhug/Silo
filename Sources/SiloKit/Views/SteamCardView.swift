import SwiftUI
import AppKit

/// A pinned card in the Library representing the Master Steam client.
struct SteamCardView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "gamecontroller.fill").foregroundStyle(.tint)
                Text("Steam").font(.headline)
                Spacer()
                Menu { menuItems } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            Text("Master library").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button {
                    Task { await env.openSteam() }
                } label: {
                    Label("Open Steam", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
        }
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .contextMenu { menuItems }
        .sheet(isPresented: $showSettings) { AdvancedSettingsSheet() }
    }

    /// Master-bottle actions, shared by the ellipsis menu and the right-click context menu.
    @ViewBuilder private var menuItems: some View {
        Button("Open Steam") { Task { await env.openSteam() } }
        Button("Reinstall Steam…") { Task { await env.backendSettings.installSteamBottle() } }
        Divider()
        Button("View Log…") {
            openWindow(id: "silo-log", value: LogTarget(title: "Steam — Log", url: env.steamLogURL))
        }
        Button("Wine Config…") { Task { await env.openMasterWinecfg() } }
        Button("Reveal Bottle in Finder") {
            if let bottle = env.backendSettings.config.masterBottlePath {
                NSWorkspace.shared.activateFileViewerSelecting([bottle])
            }
        }
        Divider()
        Button("Settings…") { showSettings = true }
    }
}
