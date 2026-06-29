import SwiftUI

/// The app's single pane: the Library (or first-run onboarding). There's no sidebar — Steam-bottle setup,
/// runtime management (GPTK/Wine), and updates all live in the **Settings** window (⌘, / the toolbar gear).
struct RootView: View {
    var body: some View {
        NavigationStack {
            LibraryGridView()
        }
    }
}
