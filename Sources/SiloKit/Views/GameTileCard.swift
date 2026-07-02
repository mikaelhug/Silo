import SwiftUI

/// The shared library-tile chrome both game kinds render: the artwork band, title + subtitle row, the
/// three-state primary button (Play / Launching… / Stop), the overflow menu, and the hover / shadow /
/// rounded-corner treatment. Type-specific pieces — artwork, subtitle row, menu items, tap action, and
/// any confirmation dialogs — are injected by `SteamGameTileView` / `ManualGameTileView`.
struct GameTileCard<Artwork: View, Subtitle: View, MenuItems: View>: View {
    let title: String
    let isRunning: Bool
    let isBusy: Bool
    let canLaunch: Bool
    let helpText: String
    let onPlay: () -> Void
    let onStop: () -> Void
    let onTap: () -> Void
    @ViewBuilder let artwork: () -> Artwork
    @ViewBuilder let subtitle: () -> Subtitle
    @ViewBuilder let menuItems: () -> MenuItems

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            artwork()
                .frame(maxWidth: .infinity, minHeight: 92, maxHeight: 92).clipped()

            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline).lineLimit(1)
                HStack(spacing: 6) { subtitle() }
                HStack(spacing: 8) {
                    primaryButton
                    Spacer()
                    Menu { menuItems() } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
            }
            .padding()
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.tint.opacity(hovering ? 0.5 : 0), lineWidth: 1))
        .shadow(color: .black.opacity(hovering ? 0.22 : 0), radius: 9, y: 4)
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { onTap() }
        .onHover { hovering = $0 }
        .help(helpText)
        .contextMenu { menuItems() }
    }

    @ViewBuilder private var primaryButton: some View {
        if isRunning {
            Button(role: .destructive, action: onStop) { Label("Stop", systemImage: "stop.fill") }
                .buttonStyle(.borderedProminent).tint(.red)
        } else if isBusy {
            Button {} label: {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Launching…") }
            }.buttonStyle(.borderedProminent).disabled(true)
        } else {
            Button(action: onPlay) { Label("Play", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent).disabled(!canLaunch)
        }
    }
}
