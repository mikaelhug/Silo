import SwiftUI

/// A small capsule tag on a manual game's library card showing its graphics-backend choice — `Auto`, `GPTK`,
/// or `DXMT`. (Steam games carry their own badge; this is the manual-card variant.)
struct BackendTag: View {
    let choice: GraphicsChoice

    var body: some View {
        Text(choice.badge)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .help(choice == .auto ? "Silo picks the backend automatically" : "Runs under \(choice.displayName)")
    }
}
