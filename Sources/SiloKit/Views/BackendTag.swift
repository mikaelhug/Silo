import SwiftUI

/// A small capsule tag on a manual game's library card showing which graphics backend (GPTK or DXMT) it
/// runs on. Steam games all run under GPTK, so only manual cards carry the tag.
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
