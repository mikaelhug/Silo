import SwiftUI

struct LibraryGridView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var settingsTarget: SteamApp?
    @State private var logTarget: SteamApp?
    @State private var showAdvanced = false

    var body: some View {
        @Bindable var library = env.library
        Group {
            if env.setupComplete {
                grid(library)
            } else {
                OnboardingView()
            }
        }
        .navigationTitle("Library")
        .toolbar {
            if env.setupComplete {
                Button {
                    Task { await library.installEntireLibrary() }
                } label: {
                    Label("Install entire library", systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(library.isQueueingInstalls || !library.canInstallLibrary)

                Button {
                    Task { await library.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            Button { showAdvanced = true } label: { Label("Advanced", systemImage: "gearshape") }
        }
        .sheet(isPresented: $showAdvanced) { AdvancedSettingsSheet() }
        .sheet(item: $settingsTarget) { GameSettingsSheet(game: $0) }
        .sheet(item: $logTarget) { LogViewerView(game: $0) }
        .searchable(text: $library.searchText, placement: .toolbar, prompt: "Search games")
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
    private func grid(_ library: LibraryViewModel) -> some View {
        ScrollView {
            if library.loadState == .loading {
                ProgressView("Scanning library…").padding()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], spacing: 16) {
                SteamCardView()
                ForEach(library.filteredGames) { game in
                    GameCardView(
                        game: game,
                        onSettings: { settingsTarget = game },
                        onLog: { logTarget = game })
                }
            }
            .padding()

            if library.games.isEmpty && library.loadState != .loading {
                ContentUnavailableView(
                    "No games yet", systemImage: "tray",
                    description: Text("Open Steam to download games, then Refresh — or use “Install entire library”."))
                    .padding()
            }
        }
    }
}

/// Advanced settings presented as a sheet (the Setup pane was removed for simplicity).
struct AdvancedSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            BackendSettingsView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
        .frame(minWidth: 580, minHeight: 560)
    }
}
