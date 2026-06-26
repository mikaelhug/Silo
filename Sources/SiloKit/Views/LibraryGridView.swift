import SwiftUI

struct LibraryGridView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var settingsTarget: SteamApp?
    @State private var logTarget: SteamApp?

    var body: some View {
        @Bindable var library = env.library
        content(library)
            .navigationTitle("Library")
            .searchable(text: $library.searchText, placement: .toolbar, prompt: "Search games")
            .toolbar {
                Button {
                    Task { await library.installEntireLibrary() }
                } label: {
                    Label("Install entire library", systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(library.isQueueingInstalls || !library.canInstallLibrary)
                .help("Queue downloads in Steam for every owned game (Steam must be running + logged in).")

                Button {
                    Task { await library.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .sheet(item: $settingsTarget) { GameSettingsSheet(game: $0) }
            .sheet(item: $logTarget) { LogViewerView(game: $0) }
            .safeAreaInset(edge: .bottom) {
                if let message = library.statusMessage {
                    Text(message)
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(8).frame(maxWidth: .infinity)
                        .background(.bar)
                }
            }
    }

    @ViewBuilder
    private func content(_ library: LibraryViewModel) -> some View {
        switch library.loadState {
        case .idle, .loading:
            ProgressView("Scanning library…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ContentUnavailableView(
                "No games found", systemImage: "tray",
                description: Text("Download games in your Master Steam bottle, then refresh."))
        case .error(let message):
            ContentUnavailableView(
                "Can't load library", systemImage: "exclamationmark.triangle",
                description: Text(message))
        case .loaded:
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], spacing: 16) {
                    ForEach(library.filteredGames) { game in
                        GameCardView(
                            game: game,
                            onSettings: { settingsTarget = game },
                            onLog: { logTarget = game })
                    }
                }
                .padding()
            }
        }
    }
}
