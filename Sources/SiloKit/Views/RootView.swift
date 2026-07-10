import SwiftUI

/// The app's single pane: the Library (or first-run onboarding). There's no sidebar — Steam-bottle setup,
/// runtime management (GPTK/Wine), and updates all live in the **Settings** window (⌘, / the toolbar gear).
///
/// Quitting Silo deliberately leaves Steam and any launched games RUNNING (like quitting CrossOver) — Silo
/// launches them detached and never owns their lifecycle, so there is no app-quit teardown.
struct RootView: View {
    var body: some View {
        NavigationStack {
            LibraryGridView()
        }
    }
}
