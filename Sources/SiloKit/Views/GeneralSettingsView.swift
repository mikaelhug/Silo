import SwiftUI

/// The **General** settings tab: Steam-bottle setup, with the app version + inline updater at the bottom.
struct GeneralSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    /// Local "a check is running" flag, kept up for a short minimum so the spinner is always perceptible
    /// (the GitHub call alone can return faster than the eye registers). Drives the row animation.
    @State private var isChecking = false

    var body: some View {
        Form {
            steamBottleSection
            bottlesSection
            updatesSection
        }
        .formStyle(.grouped)
    }

    /// Where Silo keeps its Wine bottles — movable to another disk / external drive.
    @ViewBuilder private var bottlesSection: some View {
        Section {
            LabeledContent("Location") {
                Text(env.paths.bottlesRelocated ? env.paths.bottlesRoot.path : "Application Support (default)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            if env.paths.bottlesRelocated && !env.paths.bottlesRootReachable {
                Label("This location isn't reachable — is the drive connected?",
                      systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
            }
            if env.bottlesBusy {
                if let fraction = env.bottlesProgress, fraction > 0 {
                    ProgressView(value: fraction) {
                        Text("Moving bottles…")
                    } currentValueLabel: {
                        Text("\(Int(fraction * 100))%").foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(env.bottlesMessage ?? "Moving bottles…").foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack {
                    Button("Move…") {
                        if let dir = chooseDirectory(
                            message: "Choose where to keep Silo's bottles (e.g. an external drive).") {
                            Task { await env.moveBottles(to: dir) }
                        }
                    }
                    .disabled(env.anythingRunning)
                    if env.paths.bottlesRelocated {
                        Button("Reset to Default") { Task { await env.resetBottlesLocation() } }
                            .disabled(env.anythingRunning)
                    }
                }
                if env.anythingRunning {
                    Text("Stop running games and Steam to move bottles.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let message = env.bottlesMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Bottles")
        } footer: {
            Text("Where Silo keeps its Wine bottles (the Steam bottle + each manual game's bottle). Moving "
                 + "copies the existing data, then Silo relaunches to use the new location.")
        }
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

    // MARK: - Updates

    @ViewBuilder private var updatesSection: some View {
        Section("Updates") {
            LabeledContent("Version", value: Silo.version)
            updateStatusRow
        }
    }

    /// One self-contained row that morphs between states: tapping **Check Now** spins, then the result —
    /// up-to-date, or a new version with an **Update & Relaunch** action — cross-fades in.
    private var updateStatusRow: some View {
        HStack(spacing: 12) {
            phaseIcon
                .frame(width: 26, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(phase.title)
                    .fontWeight(.medium)
                    .contentTransition(.opacity)
                if let subtitle = phase.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
            }
            Spacer(minLength: 8)
            phaseAction
        }
        .padding(.vertical, 3)
        .animation(.smooth(duration: 0.32), value: phase)
    }

    /// A spinner while busy/checking, otherwise a hierarchical, tinted SF Symbol for the state.
    @ViewBuilder private var phaseIcon: some View {
        switch phase {
        case .busy:
            ProgressView().controlSize(.small)
        default:
            Image(systemName: phase.icon)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(phase.tint)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }

    @ViewBuilder private var phaseAction: some View {
        switch phase {
        case .updateAvailable:
            Button { Task { await env.installUpdate() } } label: {
                Label("Update & Relaunch", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .transition(.opacity)
        case .upToDate, .unknown:
            Button { Task { await runCheck() } } label: {
                Label("Check Now", systemImage: "arrow.clockwise")
            }
            .transition(.opacity)
        case .failed:
            Button("Retry") { Task { await env.installUpdate() } }
                .transition(.opacity)
        case .busy:
            EmptyView()
        }
    }

    // MARK: - Phase

    /// The current visible state of the updater, derived from `env` + the local `isChecking`.
    private enum Phase: Equatable {
        case busy(String)                 // checking / downloading / installing — spinner + label
        case updateAvailable(String)      // a newer version is ready to install
        case upToDate                     // confirmed current
        case unknown                      // no successful check yet (e.g. offline at launch)
        case failed(String)               // an install attempt failed

        var title: String {
            switch self {
            case .busy(let label):      return label
            case .updateAvailable(let v): return "Version \(v) is available"
            case .upToDate:             return "You're on the latest version"
            case .unknown:              return "Check for the latest version"
            case .failed:               return "Update failed"
            }
        }
        var subtitle: String? {
            switch self {
            case .updateAvailable:      return "Download it and relaunch in place."
            case .failed(let message):  return message
            default:                    return nil
            }
        }
        var icon: String {
            switch self {
            case .updateAvailable:      return "arrow.down.circle.fill"
            case .upToDate:             return "checkmark.circle.fill"
            case .unknown:              return "arrow.triangle.2.circlepath.circle"
            case .failed:               return "exclamationmark.triangle.fill"
            case .busy:                 return ""
            }
        }
        var tint: Color {
            switch self {
            case .updateAvailable:      return .accentColor
            case .upToDate:             return .green
            case .failed:               return .orange
            case .unknown, .busy:       return .secondary
            }
        }
    }

    private var phase: Phase {
        switch env.updateState {
        case .downloading: return .busy("Downloading update…")
        case .installing:  return .busy("Installing update…")
        case .failed(let message): return .failed(message)
        case .idle:
            if isChecking { return .busy("Checking for updates…") }
            if let check = env.updateCheck, check.isNewer { return .updateAvailable(check.latestVersion) }
            return env.updateCheck != nil ? .upToDate : .unknown
        }
    }

    /// Run an update check; the spinner shows for exactly the real check duration, then the fresh
    /// `env.updateCheck` cross-fades in. No artificial floor — nothing waits.
    private func runCheck() async {
        guard !isChecking else { return }
        isChecking = true
        await env.checkForUpdate()
        isChecking = false
    }
}
