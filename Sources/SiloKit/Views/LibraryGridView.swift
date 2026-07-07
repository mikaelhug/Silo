import SwiftUI

/// The Library: Steam games installed in the bottle (launched co-resident with its Steam client under
/// GPTK) plus any manual non-Steam `.exe` games, or the first-run onboarding until Wine + GPTK + the
/// Steam bottle are ready.
struct LibraryGridView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openSettings) private var openSettings
    @State private var settingsTarget: SteamApp?
    @State private var manualSettingsTarget: ManualGame?
    @State private var detailTarget: SteamApp?
    @State private var showAddGame = false
    /// The user has dismissed the first-run onboarding. Kept SEPARATE from `setupComplete` so finishing the
    /// required steps doesn't yank the user straight into the library — they stay on onboarding (with a
    /// "Done" button) to optionally set up the DXMT bottle first. Persisted so it doesn't reappear.
    @AppStorage("onboardingDone") private var onboardingDone = false

    var body: some View {
        @Bindable var lib = env.gameLibrary
        // Compute the filter+sort ONCE; reused by the subtitle count + the grid.
        let steamShown = lib.filtered
        let manualShown = lib.filteredManual
        let showLibrary = env.setupComplete && onboardingDone
        Group {
            if env.bottlesDisconnected {
                BottlesDisconnectedView()          // a relocated drive is unplugged — reconnect, not re-setup
            } else if showLibrary {
                grid(lib, steam: steamShown, manual: manualShown)
            } else {
                OnboardingView()
            }
        }
        .navigationTitle("Library")
        .toolbar {
            if showLibrary {
                Button { Task { await lib.openSteam() } } label: { Label("Open Steam", systemImage: "cart") }
                    .help("Open the bottle's Steam to browse + install games")
                Button { showAddGame = true } label: { Label("Add Game", systemImage: "plus") }
                    .help("Add a non-Steam .exe game")
                Button { Task { await lib.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            } else if env.setupComplete {
                // Required steps done — let the user finish on their terms (after optional DXMT setup).
                Button { onboardingDone = true } label: { Label("Done", systemImage: "checkmark.circle.fill") }
                    .buttonStyle(.borderedProminent).tint(.green)
                    .help("Finish setup and go to your library")
            }
            Button { openSettings() } label: { Label("Settings", systemImage: "gearshape") }
        }
        .sheet(isPresented: $showAddGame) { AddGameSheet() }
        .sheet(item: $settingsTarget) { GameSettingsSheet(game: $0) }
        .sheet(item: $manualSettingsTarget) { ManualGameSettingsSheet(game: $0) }
        .sheet(item: $detailTarget) { game in
            GameDetailView(game: game, onSettings: { detailTarget = nil; settingsTarget = game })
        }
        .navigationSubtitle(showLibrary ? subtitle(steamShown.count + manualShown.count) : "")
        .searchable(text: $lib.searchText, placement: .toolbar, prompt: "Search games")
    }

    /// The subtitle next to the "Library" title: the game count, plus a small "Update available" note to
    /// its right when a newer release exists (apply it in Settings → General → Updates).
    private func subtitle(_ count: Int) -> String {
        let games = gameCountLabel(count)
        guard let update = env.updates.updateCheck, update.isNewer else { return games }
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

/// Add a **non-Steam** game. Each manual game gets its **own isolated bottle** (Wine prefix): point at the
/// game's `.exe` (a portable/extracted game needs only this), or first run a setup `.exe` into the new
/// bottle. (Steam games come in through "Open Steam" instead — this is for `.exe` games you have on disk.)
struct AddGameSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    /// The draft game's id — also its bottle path — fixed for this presentation so the installer and the
    /// final Add land in the same fresh bottle.
    @State private var draftID = UUID()
    @State private var name = ""
    @State private var chosenExe: URL?
    @State private var ranInstaller = false
    @State private var bottleCreated = false   // a bottle was provisioned this session (cancel → discard)
    @State private var working = false
    /// The graphics backend this game's isolated bottle runs under (GPTK default; DXMT for older/problem titles).
    @State private var backend: GraphicsBackend = .gptk

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        // After running an installer the game lands in this bottle's drive_c; otherwise
                        // (a portable game) start at the last-used location, near the extracted folder.
                        if let exe = chooseExecutable(
                            message: "Choose the game's .exe.",
                            directory: ranInstaller ? bottleDriveC : nil) {
                            chosenExe = exe
                            if name.trimmingCharacters(in: .whitespaces).isEmpty {
                                name = exe.deletingPathExtension().lastPathComponent
                            }
                        }
                    } label: {
                        Label(chosenExe == nil ? "Choose Game .exe…" : "Change .exe…",
                              systemImage: "gamecontroller")
                    }
                    .disabled(working)
                    if let chosenExe {
                        Text(chosenExe.path)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    TextField("Name", text: $name)
                } header: {
                    Text("Game")
                }

                Section {
                    Picker("Graphics", selection: $backend) {
                        ForEach(GraphicsBackend.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    Text(backend.recommendedFor)
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("Graphics Backend")
                }

                Section {
                    Button {
                        if let installer = chooseExecutable(
                            message: "Choose an installer (setup .exe) to run in this game's new bottle.") {
                            Task {
                                working = true
                                await env.gameLibrary.runInstaller(installer, forBottle: draftID)
                                bottleCreated = true
                                ranInstaller = true
                                working = false
                            }
                        }
                    } label: {
                        Label("Run Installer…", systemImage: "shippingbox")
                    }
                    .disabled(working)
                    if ranInstaller {
                        Label("Installer launched — finish its setup window, then choose the game's .exe above.",
                              systemImage: "arrow.up.forward.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Installer (only if needed)")
                }

                if working {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Setting up this game's bottle…").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add a Game")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if bottleCreated { Task { await env.gameLibrary.discardManualBottle(draftID) } }
                        dismiss()
                    }
                    .disabled(working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let chosenExe else { return }
                        Task {
                            working = true
                            let game = await env.gameLibrary.addManualGame(
                                id: draftID, name: name, executable: chosenExe, backend: backend)
                            working = false
                            if game != nil { dismiss() }
                        }
                    }
                    .disabled(chosenExe == nil || working)
                }
            }
        }
        .frame(width: 540, height: 500)
    }

    /// Initial folder for the "choose game .exe" panel — this game's bottle drive, where its installer lands.
    private var bottleDriveC: URL {
        env.paths.manualBottle(draftID).appendingPathComponent("drive_c", isDirectory: true)
    }
}

/// The Settings window (macOS "Settings…" / ⌘, and the Library toolbar gear), a tabbed pane:
/// **General** (Steam bottle, bottle tools + location, updates) plus the three runtime tabs —
/// **Wine**, **GPTK**, **DXMT**.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }
            WineDownloadView().tabItem { Label("Wine", systemImage: "wineglass") }
            GPTKManagerView().tabItem { Label("GPTK", systemImage: "cpu") }
            DXMTManagerView().tabItem { Label("DXMT", systemImage: "square.stack.3d.up") }
        }
        // Definite compact size; with the scene's `.windowResizability(.contentSize)` the WINDOW becomes
        // exactly this (no grey side-columns), a fixed-size settings pane per macOS convention.
        .frame(width: 480, height: 540)
    }
}

/// Shown when the bottles live on a relocated drive that isn't mounted — a "reconnect" state distinct from
/// first-run onboarding, so an ejected external drive doesn't read as a factory reset.
struct BottlesDisconnectedView: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        ContentUnavailableView {
            Label("Bottles drive not connected", systemImage: "externaldrive.badge.xmark")
        } description: {
            Text("Your Silo bottles are on \(env.paths.bottlesRoot.path), which isn't mounted right now. "
                + "Reconnect the drive to use your games — or move the bottles back in Settings → General.")
        } actions: {
            Button("Check Again") { Task { await env.refreshLibraryIfReady() } }
                .buttonStyle(.borderedProminent)
        }
    }
}
