import SwiftUI

/// The app's single pane: the Library (or first-run onboarding). There's no sidebar — runtime management
/// (Wine/GPTK) and updates live in **Advanced Settings**, reachable from the Library toolbar.
struct RootView: View {
    var body: some View {
        NavigationStack {
            LibraryGridView()
        }
    }
}

/// App info + the inline updater. Shown as a tab in Advanced Settings (replaces the old About pane).
struct UpdatesView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox.fill").font(.system(size: 44)).foregroundStyle(.tint)
            Text(Silo.appName).font(.title.bold())
            Text("Version \(Silo.version)").foregroundStyle(.secondary)

            if let update = env.updateCheck, update.isNewer {
                updateSection(update)
            } else {
                Text("You're up to date.").font(.callout).foregroundStyle(.secondary)
            }

            Spacer()
            Text("Isolated Wine/GPTK launcher for Windows Steam games. Silo never bundles or downloads "
                 + "Wine, GPTK, or any Steam-API emulator.")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
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
