import SwiftUI

/// The Library: owned Windows-only games (downloaded via SteamCMD, launched in GPTK buckets), or the
/// first-run onboarding until Wine + GPTK + Steam sign-in are done.
struct LibraryGridView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var settingsTarget: SteamAppInfo?
    @State private var detailTarget: SteamAppInfo?
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
                    Label(lib.account ?? env.backendSettings.config.steamUsername ?? "Account",
                          systemImage: "person.crop.circle")
                }
                .help(lib.account.map { "Signed in as \($0)" } ?? "Steam account")
                Menu {
                    Toggle("Windows-only (hide games with a Mac version)", isOn: $lib.showWindowsOnly)
                } label: { Label("Filter", systemImage: "line.3.horizontal.decrease.circle") }
                // Keep the button chrome while refreshing (spinner inside) so the toolbar group doesn't
                // shrink and crowd the spinner against its border.
                Button { Task { await lib.refresh() } } label: {
                    if lib.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(lib.isRefreshing)
            }
            Button { showAdvanced = true } label: { Label("Advanced", systemImage: "gearshape") }
        }
        .sheet(isPresented: $showAdvanced) { AdvancedSettingsSheet() }
        .sheet(isPresented: $showLogin) { SteamLoginView() }
        .sheet(item: $settingsTarget) { GameSettingsSheet(appID: $0.appID, name: $0.name) }
        .sheet(item: $detailTarget) { game in
            GameDetailView(game: game, onSettings: { detailTarget = nil; settingsTarget = game })
        }
        .navigationSubtitle(librarySubtitle(lib))
        .searchable(text: $lib.searchText, placement: .toolbar, prompt: "Search games")
    }

    /// "N games · signed in as alice" — keeps the logged-in account visible next to the library.
    private func librarySubtitle(_ lib: GameLibraryViewModel) -> String {
        guard env.setupComplete else { return "" }
        var parts = ["\(lib.filtered.count) games"]
        if let account = lib.account { parts.append("signed in as \(account)") }
        return parts.joined(separator: "  ·  ")
    }

    @ViewBuilder
    private func grid(_ lib: GameLibraryViewModel) -> some View {
        VStack(spacing: 0) {
            if lib.owned.isEmpty && lib.loadState == .loading {
                // The loading SPINNER must live OUTSIDE the ScrollView: an indeterminate ProgressView
                // inside the scrollable grid drives a CADisplayLink that re-lays out the whole grid every
                // frame → 100% CPU. (The toolbar already shows the background-refresh spinner.)
                VStack(spacing: 6) {
                    ProgressView()
                    Text("Setting up your library…").font(.headline)
                    Text("Fetching your games from Steam — cached after, so the next launch is instant.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                scrollContent(lib)
            }
            DownloadStatusBar()   // a sibling, NOT a safeAreaInset — its updates can't re-layout the grid
        }
    }

    @ViewBuilder
    private func scrollContent(_ lib: GameLibraryViewModel) -> some View {
        ScrollView {
            ForEach(sections(lib), id: \.title) { sec in
                if !sec.games.isEmpty { section(sec.title, sec.games) }
            }

            switch lib.loadState {
            case .empty:
                ContentUnavailableView("No games yet", systemImage: "tray",
                    description: Text("Sign in shows your owned Windows games here. "
                                      + "Games with a native macOS version are hidden (toggle in Filter)."))
                    .padding()
            case .error(let message):
                ContentUnavailableView("Couldn't load your library", systemImage: "exclamationmark.triangle",
                    description: Text(message)).padding()
            default:
                EmptyView()
            }
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 250), spacing: 16)]

    /// Partition the (already searched/sorted) list into Downloading / Installed / Library sections.
    private func sections(_ lib: GameLibraryViewModel) -> [(title: String, games: [SteamAppInfo])] {
        let f = lib.filtered
        return [
            ("Downloading", f.filter { lib.isDownloading($0) || lib.isPaused($0) }),
            ("Installed", f.filter { lib.isInstalled($0) }),
            ("Library", f.filter { !lib.isInstalled($0) && !lib.isDownloading($0) && !lib.isPaused($0) }),
        ]
    }

    @ViewBuilder
    private func section(_ title: String, _ games: [SteamAppInfo]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title).font(.title3.bold())
                Text("\(games.count)").font(.title3).foregroundStyle(.secondary)
                Spacer()
            }
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(games) { game in
                    SteamGameTileView(game: game,
                                      onSettings: { settingsTarget = game },
                                      onDetails: { detailTarget = game })
                }
            }
        }
        .padding(.horizontal).padding(.top, 10)
    }
}

/// Bottom status bar listing **every** active download (not just the latest) with progress + speed,
/// plus any transient status message.
struct DownloadStatusBar: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let lib = env.gameLibrary
        let active = lib.activeDownloads
        if !active.isEmpty || lib.statusMessage != nil {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(active.prefix(4)) { game in
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle").foregroundStyle(.blue).font(.caption)
                        Text(game.name).font(.caption).lineLimit(1)
                            .frame(width: 170, alignment: .leading)
                        ProgressView(value: lib.downloadProgress(game) ?? 0)
                        Text([lib.downloadProgress(game).map { "\(Int($0 * 100))%" }, lib.speedString(game)]
                                .compactMap { $0 }.joined(separator: "  ·  "))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 150, alignment: .trailing)
                    }
                }
                if active.count > 4 {
                    Text("…and \(active.count - 4) more downloading")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let message = lib.statusMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
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
