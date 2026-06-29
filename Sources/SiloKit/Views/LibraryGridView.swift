import SwiftUI

/// The Library: games installed in the Steam bottle (launched co-resident with its Steam client under
/// GPTK), or the first-run onboarding until Wine + GPTK + the Steam bottle are ready.
struct LibraryGridView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openSettings) private var openSettings
    @State private var settingsTarget: SteamApp?
    @State private var manualSettingsTarget: ManualGame?
    @State private var detailTarget: SteamApp?
    @State private var showAddGame = false

    var body: some View {
        @Bindable var lib = env.gameLibrary
        // Compute the filter+sort ONCE; reused by the subtitle count + the grid.
        let steamShown = lib.filtered
        let manualShown = lib.filteredManual
        Group {
            if env.setupComplete {
                grid(lib, steam: steamShown, manual: manualShown)
            } else {
                OnboardingView()
            }
        }
        .navigationTitle("Library")
        .toolbar {
            if env.setupComplete {
                Button { Task { await lib.openSteam() } } label: { Label("Open Steam", systemImage: "cart") }
                    .help("Open the bottle's Steam to browse + install games")
                Button { showAddGame = true } label: { Label("Add Game", systemImage: "plus") }
                    .help("Add a non-Steam .exe game")
                Button { Task { await lib.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            Button { openSettings() } label: { Label("Settings", systemImage: "gearshape") }
        }
        .sheet(isPresented: $showAddGame) { AddGameSheet() }
        .sheet(item: $settingsTarget) { GameSettingsSheet(game: $0) }
        .sheet(item: $manualSettingsTarget) { ManualGameSettingsSheet(game: $0) }
        .sheet(item: $detailTarget) { game in
            GameDetailView(game: game, onSettings: { detailTarget = nil; settingsTarget = game })
        }
        .navigationSubtitle(env.setupComplete ? subtitle(steamShown.count + manualShown.count) : "")
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
    private func grid(_ lib: GameLibraryViewModel, steam: [SteamApp], manual: [ManualGame]) -> some View {
        VStack(spacing: 0) {
            switch lib.loadState {
            case .notReady:
                ContentUnavailableView("Set up the Steam bottle", systemImage: "shippingbox",
                    description: Text("Open Settings → General → Steam bottle → Set up, then launch Steam and sign in."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                ContentUnavailableView {
                    Label("No games yet", systemImage: "tray")
                } description: {
                    Text("Install games from the bottle's Steam, or add a non-Steam .exe game.")
                } actions: {
                    Button("Open Steam") { Task { await lib.openSteam() } }
                    Button("Add Game…") { showAddGame = true }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .error(let message):
                ContentUnavailableView("Couldn't load the library", systemImage: "exclamationmark.triangle",
                    description: Text(message)).frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(steam) { game in
                            SteamGameTileView(game: game,
                                              onSettings: { settingsTarget = game },
                                              onDetails: { detailTarget = game })
                        }
                        ForEach(manual) { game in
                            ManualGameTileView(game: game,
                                               onSettings: { manualSettingsTarget = game })
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

/// Add a **non-Steam** game: optionally run its installer in the bottle, then point at the game's `.exe`.
/// (Steam games come in through "Open Steam" instead — this is for `.exe` games you have on disk.)
struct AddGameSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var chosenExe: URL?
    @State private var ranInstaller = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        if let installer = chooseExecutable(
                            message: "Choose an installer (setup .exe) to run inside the Steam bottle.") {
                            ranInstaller = true
                            Task { await env.gameLibrary.runInstaller(installer) }
                        }
                    } label: {
                        Label("Run Installer…", systemImage: "shippingbox")
                    }
                    if ranInstaller {
                        Label("Installer launched — finish its setup window, then choose the game's .exe below.",
                              systemImage: "arrow.down.forward.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("1 · Installer (optional)")
                } footer: {
                    Text("If the game ships an installer, run it here — it installs into the bottle's Windows "
                         + "drive. Skip this for a portable game you can point at directly.")
                }

                Section {
                    Button {
                        if let exe = chooseExecutable(
                            message: "Choose the game's .exe.", directory: bottleDriveC) {
                            chosenExe = exe
                            if name.trimmingCharacters(in: .whitespaces).isEmpty {
                                name = exe.deletingPathExtension().lastPathComponent
                            }
                        }
                    } label: {
                        Label(chosenExe == nil ? "Choose Game .exe…" : "Change .exe…",
                              systemImage: "gamecontroller")
                    }
                    if let chosenExe {
                        Text(chosenExe.path)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    TextField("Name", text: $name)
                } header: {
                    Text("2 · Game")
                } footer: {
                    Text("Point at the game's main executable — often under the bottle's "
                         + "drive_c/Program Files after installing.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add a Game")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let chosenExe else { return }
                        Task {
                            await env.gameLibrary.addManualGame(name: name, executable: chosenExe)
                            dismiss()
                        }
                    }
                    .disabled(chosenExe == nil)
                }
            }
        }
        .frame(width: 540, height: 480)
    }

    /// Initial folder for the "choose game .exe" panel — the bottle's Windows drive, where installers land.
    private var bottleDriveC: URL {
        env.paths.steamBottle.appendingPathComponent("drive_c", isDirectory: true)
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
