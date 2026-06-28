import SwiftUI

/// The Steam-bottle setup pane (a tab in Settings): install Windows Steam into the shared bottle, launch
/// it for a one-time sign-in, reset the login, and open its log. Runtime defaults (Wine/GPTK) are managed
/// in the Runtimes tab, not here.
struct BackendSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            steamBottleSection
        }
        .formStyle(.grouped)
    }

    /// Stand up a shared Steam bottle (real Windows Steam, signed into in-app) so Steamworks/DRM games run
    /// co-resident with a logged-in Steam client.
    @ViewBuilder private var steamBottleSection: some View {
        let bottle = env.steamBottleVM
        Section {
            Button("Set up Steam bottle") { Task { await bottle.setUp() } }
                .disabled(!bottle.canSetUp)
            Button("Launch Steam") { Task { await bottle.launchSteam() } }
                .disabled(bottle.busy || !bottle.steamInstalled)
            Button("Reset Steam login") { Task { await bottle.resetLogin() } }
                .disabled(bottle.busy || !bottle.steamInstalled)
            Button("Open bottle log") {
                openWindow(id: LogTarget.windowID,
                           value: LogTarget(title: "Steam Bottle — Log", url: env.paths.steamBottleLog))
            }
            if bottle.busy { ProgressView().controlSize(.small) }
            if !bottle.status.isEmpty {
                Text(bottle.status).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Steam bottle")
        } footer: {
            Text("For Steamworks/DRM games that need a running Steam client. “Set up” installs Windows "
                 + "Steam into a shared prefix; “Launch Steam” starts it — sign in once (it caches the "
                 + "login), then run a game and it shares this prefix.")
                .font(.caption)
        }
    }
}
