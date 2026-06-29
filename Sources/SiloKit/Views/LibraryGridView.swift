import SwiftUI

/// The Library: games installed in the Steam bottle (launched co-resident with its Steam client under
/// GPTK), or the first-run onboarding until Wine + GPTK + the Steam bottle are ready.
struct LibraryGridView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openSettings) private var openSettings
    @State private var settingsTarget: SteamApp?
    @State private var detailTarget: SteamApp?
    @State private var showAddGame = false

    var body: some View {
        @Bindable var lib = env.gameLibrary
        let shown = lib.filtered   // compute the filter+sort ONCE; reused by the subtitle count + the grid
        Group {
            if env.setupComplete {
                grid(lib, shown: shown)
            } else {
                OnboardingView()
            }
        }
        .navigationTitle("Library")
        .toolbar {
            if env.setupComplete {
                Button { Task { await lib.openSteam() } } label: { Label("Open Steam", systemImage: "cart") }
                    .help("Open the bottle's Steam to browse + install games")
                Button { showAddGame = true } label: { Label("Install Game", systemImage: "plus") }
                Button { Task { await lib.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            Button { openSettings() } label: { Label("Settings", systemImage: "gearshape") }
        }
        .sheet(isPresented: $showAddGame) { AddGameSheet() }
        .sheet(item: $settingsTarget) { GameSettingsSheet(game: $0) }
        .sheet(item: $detailTarget) { game in
            GameDetailView(game: game, onSettings: { detailTarget = nil; settingsTarget = game })
        }
        .navigationSubtitle(env.setupComplete ? subtitle(shown.count) : "")
        .searchable(text: $lib.searchText, placement: .toolbar, prompt: "Search games")
    }

    /// The subtitle next to the "Library" title: the game count, plus a small "Update available" note to
    /// its right when a newer release exists (apply it in Settings → General → Updates).
    private func subtitle(_ count: Int) -> String {
        let games = gameCountLabel(count)
        guard let update = env.updateCheck, update.isNewer else { return games }
        return "\(games)   ·   Update \(update.latestVersion) available"
    }

    /// "1 game" / "N games" — singular only when exactly one.
    private func gameCountLabel(_ count: Int) -> String {
        "\(count) \(count == 1 ? "game" : "games")"
    }

    private let columns = [GridItem(.adaptive(minimum: 250), spacing: 16)]

    @ViewBuilder
    private func grid(_ lib: GameLibraryViewModel, shown: [SteamApp]) -> some View {
        VStack(spacing: 0) {
            switch lib.loadState {
            case .notReady:
                ContentUnavailableView("Set up the Steam bottle", systemImage: "shippingbox",
                    description: Text("Open Settings → General → Steam bottle → Set up, then launch Steam and sign in."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                ContentUnavailableView {
                    Label("No games installed yet", systemImage: "tray")
                } description: {
                    Text("Install games from the bottle's Steam, then Refresh.")
                } actions: {
                    Button("Open Steam") { Task { await lib.openSteam() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .error(let message):
                ContentUnavailableView("Couldn't load the library", systemImage: "exclamationmark.triangle",
                    description: Text(message)).frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(shown) { game in
                            SteamGameTileView(game: game,
                                              onSettings: { settingsTarget = game },
                                              onDetails: { detailTarget = game })
                        }
                    }
                    .padding()
                }
            }
            if let message = lib.statusMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
            }
        }
    }
}

/// Install a game into the bottle by App ID — opens the bottle's Steam to its install dialog.
struct AddGameSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var appIDText = ""

    private var appID: Int? {
        let trimmed = appIDText.trimmingCharacters(in: .whitespaces)
        guard let id = Int(trimmed), id > 0 else { return nil }
        return id
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Steam App ID (e.g. 220)", text: $appIDText).autocorrectionDisabled()
                } header: {
                    Text("Install a game by App ID")
                } footer: {
                    Text("The App ID is the number in the game's Steam store URL "
                         + "(store.steampowered.com/app/<ID>). Silo opens the bottle's Steam to its install "
                         + "dialog; once it finishes downloading there, Refresh the library.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Install Game")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Install") {
                        guard let appID else { return }
                        Task { await env.gameLibrary.install(appID: appID) }
                        dismiss()
                    }
                    .disabled(appID == nil)
                }
            }
        }
        .frame(width: 440, height: 240)
    }
}

/// The Settings window (macOS "Settings…" / ⌘, and the Library toolbar gear), a tabbed pane:
/// **General** (Steam bottle + updates), **GPTK**, **Wine**.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }
            GPTKManagerView().tabItem { Label("GPTK", systemImage: "cpu") }
            WineDownloadView().tabItem { Label("Wine", systemImage: "wineglass") }
        }
        .frame(minWidth: 600, minHeight: 560)
    }
}
