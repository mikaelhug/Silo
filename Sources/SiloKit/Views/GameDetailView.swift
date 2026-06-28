import SwiftUI
import AppKit

/// Detail sheet for a game: hero art, description, developer/genres/release, and the primary actions.
/// Rich metadata is fetched from the Steam store on open (cached by URLSession).
struct GameDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    let game: SteamApp
    let onSettings: () -> Void
    @State private var details: SteamStoreDetails?
    @State private var loading = true
    @State private var showRequirements = false
    @State private var confirmingUninstall = false

    var body: some View {
        let lib = env.gameLibrary
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AsyncImage(url: details?.headerImageURL ?? game.headerArtURL) { phase in
                        switch phase {
                        case .success(let image): image.resizable().aspectRatio(contentMode: .fit)
                        default: GameArtworkPlaceholder(iconFont: .largeTitle).aspectRatio(460.0 / 215.0, contentMode: .fit)
                        }
                    }
                    .frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 12))

                    actions(lib)

                    if loading && details == nil {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Loading details…").foregroundStyle(.secondary) }
                    }
                    if let d = details {
                        if !d.genres.isEmpty { chips(d.genres) }
                        if let desc = d.shortDescription, !desc.isEmpty {
                            Text(desc).font(.callout).foregroundStyle(.secondary)
                        }
                        metadata(d)
                        requirements(d)
                    }
                }
                .padding(20)
            }
            .navigationTitle(game.name)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem {
                    Button("Store") { if let url = game.storePageURL { NSWorkspace.shared.open(url) } }
                }
            }
        }
        .frame(width: 560, height: 620)
        .task {
            details = await env.steamStore.details(appID: game.appID)
            loading = false
        }
    }

    @ViewBuilder private func actions(_ lib: GameLibraryViewModel) -> some View {
        HStack(spacing: 10) {
            if lib.isRunning(game) {
                Button(role: .destructive) { Task { await lib.stop(game) } } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(.borderedProminent).tint(.red)
            } else {
                Button { Task { await lib.play(game) } } label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).disabled(!lib.canLaunch || lib.isBusy(game))
            }
            Button("Settings…", action: onSettings)
            Button("Log") {
                openWindow(id: LogTarget.windowID, value: env.logTarget(for: game))
            }
            Spacer()
            Button(role: .destructive) { confirmingUninstall = true } label: {
                Label("Uninstall", systemImage: "trash")
            }
        }
        .uninstallConfirmation(game: game, isPresented: $confirmingUninstall, library: lib)
    }

    @ViewBuilder private func chips(_ items: [String]) -> some View {
        HStack {
            ForEach(items.prefix(5), id: \.self) { genre in
                Text(genre).font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
        }
    }

    @ViewBuilder private func metadata(_ d: SteamStoreDetails) -> some View {
        let lib = env.gameLibrary
        VStack(alignment: .leading, spacing: 4) {
            if !d.developers.isEmpty { LabeledContent("Developer", value: d.developers.joined(separator: ", ")) }
            if !d.publishers.isEmpty { LabeledContent("Publisher", value: d.publishers.joined(separator: ", ")) }
            if let date = d.releaseDate, !date.isEmpty { LabeledContent("Released", value: date) }
            // Storage: the on-disk size once installed, otherwise the store's minimum-spec requirement.
            if let installed = lib.sizeString(game) {
                LabeledContent("Disk size", value: installed)
            } else if let space = d.diskSpace {
                LabeledContent("Disk size", value: space)
            }
            if let metacritic = d.metacritic {
                LabeledContent("Metacritic", value: "\(metacritic)")
            }
            backendRecommendation(d)
        }
        .font(.callout)
    }

    /// Show the recommended graphics backend for this game (with the DirectX signal behind it), so the
    /// per-game default is transparent and the user can override it in Settings.
    @ViewBuilder private func backendRecommendation(_ d: SteamStoreDetails) -> some View {
        let cfg = env.backendSettings.config
        let recommended = BackendPolicy.recommended(
            gptkInstalled: cfg.gptkLibDirPath != nil, crossoverInstalled: cfg.crossoverWinePath != nil)
        LabeledContent("Recommended backend", value: recommended.displayName)
        Text(BackendPolicy.rationale(directXVersion: d.directXVersion, recommended: recommended))
            .font(.caption).foregroundStyle(.secondary)
    }

    /// Collapsible minimum system requirements (the full spec, incl. storage), shown only when present.
    @ViewBuilder private func requirements(_ d: SteamStoreDetails) -> some View {
        if let req = d.minimumRequirements, !req.isEmpty {
            DisclosureGroup("Minimum requirements", isExpanded: $showRequirements) {
                Text(req).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .font(.callout)
        }
    }
}
