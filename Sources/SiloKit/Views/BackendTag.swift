import SwiftUI

/// A small capsule tag on a library card showing which graphics backend — i.e. which bottle — the game
/// runs on (GPTK or DXMT). Shown on every card (Steam + manual) so the split is visible at a glance.
struct BackendTag: View {
    let backend: GraphicsBackend

    var body: some View {
        Text(backend.badge)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .help("Runs under \(backend.displayName)")
    }
}
