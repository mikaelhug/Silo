import SwiftUI
import AppKit

/// The app's single pane: the Library (or first-run onboarding). There's no sidebar — Steam-bottle setup,
/// runtime management (GPTK/Wine), and updates all live in the **Settings** window (⌘, / the toolbar gear).
struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    /// Opt-in (Settings → General): SIGTERM Silo-launched games on quit. Off by default.
    @AppStorage("stopGamesOnQuit") private var stopGamesOnQuit = false

    var body: some View {
        NavigationStack {
            LibraryGridView()
        }
        // Clean up games Silo launched as the app quits (never the co-resident Steam client), so they don't
        // outlive the launcher as unmanageable processes. willTerminate fires only on a real quit (not when
        // backgrounded), and the handler runs synchronously on the main thread before the app exits.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            if stopGamesOnQuit { env.gameLibrary.terminateAllSync() }
        }
    }
}
