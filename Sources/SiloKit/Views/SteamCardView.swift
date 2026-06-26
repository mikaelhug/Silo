import SwiftUI

/// A pinned card in the Library representing the Master Steam client.
struct SteamCardView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "gamecontroller.fill").foregroundStyle(.tint)
                Text("Steam").font(.headline)
                Spacer()
            }
            Text("Master library").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button {
                    Task { await env.openSteam() }
                } label: {
                    Label("Open Steam", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
        }
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
