import SwiftUI
import AppKit

/// The **General** settings tab: Steam-bottle setup + tools, bottle location, and the inline updater.
struct GeneralSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    /// Local "an update check is running" flag — drives the row's spinner/animation for the duration of
    /// the GitHub call.
    @State private var isChecking = false

    /// When set, Silo SIGTERMs the games it launched as it quits (never the co-resident Steam client).
    /// Default off so quitting the launcher never surprises a user mid-game. Read by `RootView`'s
    /// `willTerminate` hook.
    @AppStorage("stopGamesOnQuit") private var stopGamesOnQuit = false

    var body: some View {
        Form {
            steamBottleSection
            dxmtBottleSection
            bottleToolsSection
            bottlesSection
            updatesSection
        }
        .formStyle(.grouped)
    }

    /// Per-bottle Wine knobs + escape-hatch tools for the shared Steam bottle. Retina/HiDPI is the common
    /// fix for wrong-sized game windows on Retina Macs; the tool buttons let users repair the prefix by hand.
    @ViewBuilder private var bottleToolsSection: some View {
        let configured = env.wineBinary != nil
        Section {
            Toggle("Retina / HiDPI mode", isOn: Binding(
                get: { env.backendSettings.config.retinaMode },
                set: { on in Task { await env.setSteamBottleRetina(on) } }))
                .disabled(!configured || env.bottleToolsBusy)

            LabeledContent("Repair") {
                HStack(spacing: 8) {
                    Button("Wine Config") { Task { await env.openWineTool("winecfg") } }
                    Button("Registry") { Task { await env.openWineTool("regedit") } }
                    Button("Control Panel") { Task { await env.openWineTool("control") } }
                }
                .disabled(!configured)
            }
            Button("Reveal Bottle in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([env.paths.steamBottle])
            }
            Toggle("Stop running games when Silo quits", isOn: $stopGamesOnQuit)
            if let message = env.bottleToolsMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Bottle tools")
        }
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
            if env.bottles.busy {
                if let fraction = env.bottles.progress, fraction > 0 {
                    ProgressView(value: fraction) {
                        Text("Moving bottles…")
                    } currentValueLabel: {
                        Text("\(Int(fraction * 100))%").foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(env.bottles.message ?? "Moving bottles…").foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack {
                    Button("Move…") {
                        if let dir = chooseDirectory(message: "Choose a folder for Silo's bottles.") {
                            Task { await env.bottles.moveBottles(to: dir) }
                        }
                    }
                    .disabled(env.anythingRunning)
                    if env.paths.bottlesRelocated {
                        Button("Reset to Default") { Task { await env.bottles.resetBottlesLocation() } }
                            .disabled(env.anythingRunning)
                    }
                }
                if env.anythingRunning {
                    Text("Stop games and Steam first.").font(.caption).foregroundStyle(.secondary)
                } else if let message = env.bottles.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Bottles")
        }
    }

    /// Stand up a shared Steam bottle (real Windows Steam, signed into in-app) so Steamworks/DRM games run
    /// co-resident with a logged-in Steam client. The GPTK (default) bottle.
    @ViewBuilder private var steamBottleSection: some View {
        Section {
            SteamBottleControls(
                bottle: env.steamBottleVM, noun: "Steam",
                logButtonTitle: "Open bottle log",
                logWindowTitle: "Steam Bottle — Log", logURL: env.paths.steamBottleLog)
        } header: {
            Text("Steam bottle (GPTK)")
        }
    }

    /// The DXMT Steam bottle — its own Steam install/login (machine tokens are per-prefix), for the older
    /// DirectX 10/11 titles GPTK can't run. Set up its runtime in the DXMT tab first.
    @ViewBuilder private var dxmtBottleSection: some View {
        Section {
            SteamBottleControls(
                bottle: env.dxmtBottleVM, noun: "DXMT Steam",
                logButtonTitle: "Open bottle log",
                logWindowTitle: "DXMT Steam Bottle — Log", logURL: env.paths.steamBottleLog(.dxmt))
            LabeledContent("Repair") {
                HStack(spacing: 8) {
                    Button("Wine Config") { Task { await env.openWineTool("winecfg", for: .dxmt) } }
                    Button("Registry") { Task { await env.openWineTool("regedit", for: .dxmt) } }
                    Button("Control Panel") { Task { await env.openWineTool("control", for: .dxmt) } }
                }
                .disabled(env.wineBinary == nil || !env.dxmtSteamReady)
            }
        } header: {
            Text("Steam bottle (DXMT)")
        } footer: {
            Text("For DirectX 10/11 titles GPTK can't run. Install the DXMT runtime in the DXMT tab first.")
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
            Button { Task { await env.updates.installUpdate() } } label: {
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
            Button("Retry") { Task { await env.updates.installUpdate() } }
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
            case .failed(let message):  return message   // crucial: why it failed
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
        switch env.updates.updateState {
        case .downloading: return .busy("Downloading update…")
        case .installing:  return .busy("Installing update…")
        case .failed(let message): return .failed(message)
        case .idle:
            if isChecking { return .busy("Checking for updates…") }
            if let check = env.updates.updateCheck, check.isNewer { return .updateAvailable(check.latestVersion) }
            return env.updates.updateCheck != nil ? .upToDate : .unknown
        }
    }

    /// Run an update check; the spinner shows for exactly the real check duration, then the fresh
    /// `env.updates.updateCheck` cross-fades in. No artificial floor — nothing waits.
    private func runCheck() async {
        guard !isChecking else { return }
        isChecking = true
        await env.updates.checkForUpdate()
        isChecking = false
    }
}

/// The Setup / Launch / Reset-login / open-log control block a Steam bottle renders in Settings — one
/// implementation shared by the GPTK and DXMT sections (identical flow, different bottle + labels).
struct SteamBottleControls: View {
    @Environment(\.openWindow) private var openWindow
    let bottle: SteamBottleViewModel
    /// How the buttons name this bottle's Steam ("Steam" / "DXMT Steam").
    let noun: String
    let logButtonTitle: String
    let logWindowTitle: String
    let logURL: URL

    var body: some View {
        Button("Set up \(noun) bottle") { Task { await bottle.setUp() } }
            .disabled(!bottle.canSetUp)
        Button("Launch \(noun)") { Task { await bottle.launchSteam() } }
            .disabled(bottle.busy || !bottle.steamInstalled)
        Button("Reset \(noun) login") { Task { await bottle.resetLogin() } }
            .disabled(bottle.busy || !bottle.steamInstalled)
        Button(logButtonTitle) {
            openWindow(id: LogTarget.windowID, value: LogTarget(title: logWindowTitle, url: logURL))
        }
        if bottle.busy { ProgressView().controlSize(.small) }
        if !bottle.status.isEmpty {
            Text(bottle.status).font(.caption).foregroundStyle(.secondary)
        }
    }
}
