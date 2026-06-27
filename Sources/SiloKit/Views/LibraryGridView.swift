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
                    Label(env.backendSettings.config.steamUsername ?? "Account", systemImage: "person.crop.circle")
                }
                Menu {
                    Toggle("Windows-only (hide games with a Mac version)", isOn: $lib.showWindowsOnly)
                } label: { Label("Filter", systemImage: "line.3.horizontal.decrease.circle") }
                if lib.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await lib.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                }
            }
            Button { showAdvanced = true } label: { Label("Advanced", systemImage: "gearshape") }
        }
        .sheet(isPresented: $showAdvanced) { AdvancedSettingsSheet() }
        .sheet(isPresented: $showLogin) { SteamLoginView() }
        .sheet(item: $settingsTarget) { GameSettingsSheet(appID: $0.appID, name: $0.name) }
        .sheet(item: $detailTarget) { game in
            GameDetailView(game: game, onSettings: { detailTarget = nil; settingsTarget = game })
        }
        .navigationSubtitle(env.setupComplete ? "\(lib.filtered.count) games" : "")
        .searchable(text: $lib.searchText, placement: .toolbar, prompt: "Search games")
        .safeAreaInset(edge: .bottom) { DownloadStatusBar() }
    }

    @ViewBuilder
    private func grid(_ lib: GameLibraryViewModel) -> some View {
        ScrollView {
            if lib.loadState == .loading {
                VStack(spacing: 6) {
                    ProgressView()
                    Text("Setting up your library…").font(.headline)
                    Text("Fetching your games from Steam — this is cached, so the next launch is instant.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(40)
            } else if lib.isRefreshing && !lib.owned.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Updating library…").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.top, 10)
            }

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
