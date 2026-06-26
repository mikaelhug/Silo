import Foundation

/// Detects an installed Wine/GPTK backend (Whisky, Kegworks, CrossOver) by probing standard
/// locations. Pure / read-only. Returns `detectedSource == .none` on a clean machine (the current
/// state of this Mac), which the UI surfaces as a "configure a backend" empty state.
public struct BackendResolver: Sendable {
    public init() {}
    private var fileManager: FileManager { .default }

    private struct Candidate {
        let source: BackendConfig.DetectedSource
        let wine: URL
        let crossoverWine: URL?
        let gptkLib: URL?
        let dxvkDLL: URL?
    }

    /// Probe standard locations; returns the first backend whose wine binary exists.
    public func autodetect(homeDirectory: URL? = nil, applicationsDirectory: URL? = nil) -> BackendConfig {
        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        let apps = applicationsDirectory ?? URL(fileURLWithPath: "/Applications")

        for candidate in candidates(home: home, apps: apps)
        where fileManager.fileExists(atPath: candidate.wine.path) {
            return BackendConfig(
                wineBinaryPath: candidate.wine,
                crossoverWinePath: candidate.crossoverWine,
                gptkLibDirPath: existingOrNil(candidate.gptkLib),
                dxvkDLLDirPath: existingOrNil(candidate.dxvkDLL),
                detectedSource: candidate.source
            )
        }
        return BackendConfig(detectedSource: .none)
    }

    private func candidates(home: URL, apps: URL) -> [Candidate] {
        let whisky = home.appendingPathComponent(
            "Library/Application Support/com.isaacmarovitz.Whisky/Libraries", isDirectory: true)
        let kegworks = home.appendingPathComponent(
            "Library/Application Support/Kegworks/Libraries", isDirectory: true)
        let crossover = apps.appendingPathComponent(
            "CrossOver.app/Contents/SharedSupport/CrossOver", isDirectory: true)

        return [
            Candidate(
                source: .whisky,
                wine: whisky.appendingPathComponent("Wine/bin/wine64"),
                crossoverWine: nil,
                gptkLib: whisky.appendingPathComponent("GPTK"),
                dxvkDLL: whisky.appendingPathComponent("DXVK")),
            Candidate(
                source: .kegworks,
                wine: kegworks.appendingPathComponent("Wine/bin/wine64"),
                crossoverWine: nil,
                gptkLib: kegworks.appendingPathComponent("GPTK"),
                dxvkDLL: kegworks.appendingPathComponent("DXVK")),
            Candidate(
                source: .crossover,
                wine: crossover.appendingPathComponent("bin/wine64"),
                crossoverWine: crossover.appendingPathComponent("bin/wine64"),
                gptkLib: nil,
                dxvkDLL: nil),
        ]
    }

    private func existingOrNil(_ url: URL?) -> URL? {
        guard let url, fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }
}
