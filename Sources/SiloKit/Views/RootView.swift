import SwiftUI
import AppKit

/// The app's single pane: the Library (or first-run onboarding). There's no sidebar — Steam-bottle setup,
/// runtime management (GPTK/Wine), and updates all live in the **Settings** window (⌘, / the toolbar gear).
struct RootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        NavigationStack {
            LibraryGridView()
        }
        // Tear down everything Silo launched as the app quits — its games AND each bottle's Steam client — so
        // nothing outlives the launcher as an orphaned process (quitting Silo behaves like quitting Steam,
        // and keeps the in-memory liveness the safety gates rely on accurate across restarts). willTerminate
        // fires only on a real quit (not when backgrounded) and runs synchronously before the app exits.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            env.terminateAllOnQuit()
        }
    }
}
