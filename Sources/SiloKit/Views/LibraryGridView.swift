import SwiftUI

/// The Library: owned Windows-only games (downloaded via SteamCMD, launched in GPTK buckets), or the
/// first-run onboarding until Wine + GPTK + Steam sign-in are done.
struct LibraryGridView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var settingsTarget: SteamAppInfo?
    @State private var showAdvanced = false
    @State private var showLogin = false

    var body: some View {
        @Bindable var lib = env.gameLibrary
        Group {
            if env.setupComplete {
                grid(lib)
            } else {
                OnboardingView(showLogin: $showLogin)
            }
        }
        .navigationTitle("Library")
        .toolbar {
            if env.setupComplete {
                Button { showLogin = true } label: {
                    Label(env.backendSettings.config.steamUsername ?? "Account", systemImage: "person.crop.circle")
                }
                Button { Task { await lib.load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            Button { showAdvanced = true } label: { Label("Advanced", systemImage: "gearshape") }
        }
        .sheet(isPresented: $showAdvanced) { AdvancedSettingsSheet() }
        .sheet(isPresented: $showLogin) { SteamLoginView() }
        .sheet(item: $settingsTarget) { GameSettingsSheet(appID: $0.appID, name: $0.name) }
        .searchable(text: $lib.searchText, placement: .toolbar, prompt: "Search games")
        .safeAreaInset(edge: .bottom) {
            if let message = lib.statusMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .padding(8).frame(maxWidth: .infinity).background(.bar)
            }
        }
    }

    @ViewBuilder
    private func grid(_ lib: GameLibraryViewModel) -> some View {
        ScrollView {
            if lib.loadState == .loading {
                ProgressView("Loading your Steam library…").padding()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], spacing: 16) {
                ForEach(lib.filtered) { game in
                    SteamGameTileView(game: game, onSettings: { settingsTarget = game })
                }
            }
            .padding()

            switch lib.loadState {
            case .empty:
                ContentUnavailableView("No Windows-only games", systemImage: "tray",
                    description: Text("Games with a native macOS version run in the Steam app directly. "
                                      + "Only your Windows-only titles appear here."))
                    .padding()
            case .error(let message):
                ContentUnavailableView("Couldn't load your library", systemImage: "exclamationmark.triangle",
                    description: Text(message)).padding()
            default:
                EmptyView()
            }
        }
    }
}

/// Advanced settings presented as a sheet (Wine/GPTK paths etc.).
struct AdvancedSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            BackendSettingsView()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .frame(minWidth: 580, minHeight: 560)
    }
}
