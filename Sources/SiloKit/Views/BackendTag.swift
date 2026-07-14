import SwiftUI

/// A small capsule tag on a manual game's library card showing its graphics-backend choice — `Auto`, `GPTK`,
/// or `DXMT`. Only manual cards carry it (Steam tiles show install size instead).
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
