import Foundation

/// Detects an installed Wine/GPTK backend (Whisky, Kegworks) by probing standard locations. Pure /
/// read-only. Returns `detectedSource == .none` on a clean machine (the current state of this Mac),
/// which the UI surfaces as a "configure a backend" empty state.
public struct BackendResolver: Sendable {
    public init() {}
    private var fileManager: FileManager { .default }

    private struct Candidate {
        let source: BackendConfig.DetectedSource
        let wine: URL
        let gptkLib: URL?
    }

    /// Probe standard locations; returns the first backend whose wine binary exists.
    public func autodetect(homeDirectory: URL? = nil) -> BackendConfig {
        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser

        for candidate in candidates(home: home)
        where fileManager.fileExists(atPath: candidate.wine.path) {
            return BackendConfig(
                wineBinaryPath: candidate.wine,
                gptkLibDirPath: existingOrNil(candidate.gptkLib),
                detectedSource: candidate.source
            )
        }
        return BackendConfig(detectedSource: .none)
    }

    private func candidates(home: URL) -> [Candidate] {
        let whisky = home.appendingPathComponent(
            "Library/Application Support/com.isaacmarovitz.Whisky/Libraries", isDirectory: true)
        let kegworks = home.appendingPathComponent(
            "Library/Application Support/Kegworks/Libraries", isDirectory: true)

        return [
            Candidate(
                source: .whisky,
                wine: whisky.appendingPathComponent("Wine/bin/wine64"),
                gptkLib: whisky.appendingPathComponent("GPTK")),
            Candidate(
                source: .kegworks,
                wine: kegworks.appendingPathComponent("Wine/bin/wine64"),
                gptkLib: kegworks.appendingPathComponent("GPTK")),
        ]
    }

    private func existingOrNil(_ url: URL?) -> URL? {
        guard let url, fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }
}
