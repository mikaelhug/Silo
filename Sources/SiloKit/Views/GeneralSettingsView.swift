import SwiftUI

/// The **General** settings tab: Steam-bottle setup, with the app version + inline updater at the bottom.
struct GeneralSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            steamBottleSection
            updatesSection
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
        }
    }

    /// App version + the inline updater (download → in-place self-replace → relaunch).
    @ViewBuilder private var updatesSection: some View {
        Section {
            LabeledContent("Version", value: Silo.version)
            switch env.updateState {
            case .downloading:
                LabeledContent("Updating") { ProgressView("Downloading…").controlSize(.small) }
            case .installing:
                LabeledContent("Updating") { ProgressView("Installing…").controlSize(.small) }
            case .failed(let message):
                Button("Retry update") { Task { await env.installUpdate() } }
                Text(message).font(.caption).foregroundStyle(.red)
            case .idle:
                if let update = env.updateCheck, update.isNewer {
                    Button("Update to \(update.latestVersion) & Relaunch") { Task { await env.installUpdate() } }
                        .buttonStyle(.borderedProminent)
                }
                LabeledContent("Check for updates") {
                    Button(env.isCheckingForUpdate ? "Checking…" : "Check Now") {
                        Task { await env.checkForUpdate() }
                    }
                    .disabled(env.isCheckingForUpdate)
                }
                if let message = env.updateMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Updates")
        }
    }
}
