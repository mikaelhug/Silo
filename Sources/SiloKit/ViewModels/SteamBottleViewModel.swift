import Foundation

/// Drives the experimental Steam-bottle setup + launch (the revert path for Steamworks/DRM games):
/// install Windows Steam into the shared bottle, seed the macOS login so it comes up authenticated, and
/// launch it in the background. The on-device validation surface for "does a co-resident, seeded Steam
/// client serve Steamworks for games in its prefix".
@MainActor
@Observable
public final class SteamBottleViewModel {
    public private(set) var status: String = ""
    public private(set) var busy = false

    private let bottle: SteamBottle
    private var wineBinary: URL?

    public init(bottle: SteamBottle) { self.bottle = bottle }

    public func updateWine(_ url: URL?) { wineBinary = url }
    public var steamInstalled: Bool { bottle.isSteamInstalled }
    public var canSetUp: Bool { wineBinary != nil && !busy }

    /// Install Windows Steam into the bottle (if needed) and seed the macOS login.
    public func setUp() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            status = "Installing Windows Steam into the bottle… (first time downloads SteamSetup)"
            try await bottle.installSteam(wine: wineBinary)
            status = "Seeding your macOS Steam login…"
            let copied = try bottle.seedLogin()
            status = "Ready. Seeded: \(copied.joined(separator: ", ")). Launch Steam, then a game, to verify."
        } catch {
            status = "Setup failed: \(message(error))"
        }
    }

    /// Re-copy the macOS login into the bottle (e.g. after re-logging-in to macOS Steam).
    public func reseedLogin() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let copied = try bottle.seedLogin()
            status = "Re-seeded login: \(copied.joined(separator: ", "))."
        } catch {
            status = "Seeding failed: \(message(error)). Sign in to the macOS Steam app first."
        }
    }

    /// Launch the bottle's Steam client in the background.
    public func launchSteam() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            _ = try await bottle.launchSteam(wine: wineBinary)
            status = "Launched Steam (background). Give it a moment, then check the bottle log."
        } catch {
            status = "Launch failed: \(message(error))"
        }
    }

    private func message(_ error: Error) -> String { (error as NSError).localizedDescription }
}
