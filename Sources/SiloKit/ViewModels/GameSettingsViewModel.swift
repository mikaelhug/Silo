import Foundation

@MainActor
@Observable
public final class GameSettingsViewModel {
    public var config: GameConfig
    /// Set when a save fails (config.json unwritable) — the sheet stays open and shows it.
    public private(set) var errorMessage: String?
    private let configStore: ConfigStore

    public init(config: GameConfig, configStore: ConfigStore) {
        self.config = config
        self.configStore = configStore
    }

    /// Whether Automatic is currently routing this game to a reactively-learned backend (so the sheet can
    /// explain why "Automatic" is on DXMT and offer to re-probe GPTK). A user pin (`.gptk`/`.dxmt`) is not a
    /// learned hint, so it never shows here.
    public var learnedBackend: GraphicsBackend? {
        config.graphics == .auto ? config.learnedBackend : nil
    }

    /// Discard a reactively-learned backend hint so the next Automatic launch re-probes GPTK (e.g. after a
    /// GPTK update that may now run the title). Persists immediately — independent of Save — and clears the
    /// in-sheet config so the row disappears.
    public func reprobeGPTK() async {
        do {
            _ = try await configStore.updateGame(appID: config.appID) {
                $0.learnedBackend = nil; $0.learnedUnderRuntime = nil
            }
            config.learnedBackend = nil; config.learnedUnderRuntime = nil
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't save: \((error as NSError).localizedDescription)"
        }
    }

    /// Persist the edited config. Returns whether it saved — callers only dismiss on success.
    @discardableResult
    public func save() async -> Bool {
        // Snapshot the user-editable fields (all Sendable) before the @Sendable mutation closure.
        let appID = config.appID
        let (envFlags, presence, graphics) = (config.envFlags, config.presence, config.graphics)
        let (exePath, args) = (config.executableRelativePath, config.customArgs)
        do {
            // Field-merge into the CURRENT record rather than upserting the whole snapshot captured when the
            // sheet opened — otherwise a `lastPlayed` written by launching the same game while the sheet is
            // open (via `updateGame`) is reverted on save. Only the user-editable fields are applied.
            _ = try await configStore.updateGame(appID: appID) {
                $0.envFlags = envFlags
                $0.presence = presence
                // A deliberate change to the graphics choice retires any reactively-learned hint, so switching
                // back to Automatic genuinely re-probes GPTK (and a pin isn't quietly overridden by a stale
                // learned DXMT). An unrelated Save leaves the hint — and the learned routing — intact.
                if $0.graphics != graphics { $0.learnedBackend = nil; $0.learnedUnderRuntime = nil }
                $0.graphics = graphics
                $0.executableRelativePath = exePath
                $0.customArgs = args
            }
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Couldn't save: \((error as NSError).localizedDescription)"
            return false
        }
    }
}
