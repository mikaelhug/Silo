import Foundation

/// Metadata for a Steam app, parsed from SteamCMD `app_info_print` output. Drives the library filter
/// (and the per-game GPTK bucket defaults). `Codable` so the library can be cached to disk.
public struct SteamAppInfo: Sendable, Equatable, Identifiable, Codable {
    public let appID: Int
    public let name: String
    /// Platforms from `common/oslist`, e.g. `["windows", "macos", "linux"]`.
    public let oslist: [String]
    /// `common/type`, e.g. "game", "tool", "demo".
    public let type: String?

    public var id: Int { appID }

    public init(appID: Int, name: String, oslist: [String], type: String? = nil) {
        self.appID = appID
        self.name = name
        self.oslist = oslist
        self.type = type
    }

    public var supportsWindows: Bool { oslist.contains { $0.caseInsensitiveCompare("windows") == .orderedSame } }
    public var supportsMac: Bool {
        oslist.contains { ["macos", "macosx", "mac"].contains($0.lowercased()) }
    }
    /// A game that runs on Windows but has **no** native macOS build.
    public var isWindowsOnly: Bool { supportsWindows && !supportsMac }
    /// Strictly a game (type == "game"). Missing/other types (Tool like Proton, Application, Demo, DLC,
    /// Config, Music, …) are NOT games — keeps runtimes and un-typed apps out of the library.
    public var isGame: Bool { type?.caseInsensitiveCompare("game") == .orderedSame }

    /// Whether to list in Silo: an owned **game** (strictly typed) that runs on Windows. Mac-capable
    /// games are still returned by the enumerator; the UI hides them by default via the Windows-only toggle.
    public var windowsPlayable: Bool { isGame && supportsWindows }

    // MARK: - Parsing

    /// Parse one app's block out of SteamCMD's noisy `app_info_print` output.
    public static func parse(appInfoOutput output: String, appID: Int) -> SteamAppInfo? {
        guard let block = extractBlock(output, key: String(appID)),
              let root = try? KeyValuesParser().parse(text: block),
              let app = root[String(appID)] else { return nil }
        let common = app["common"]
        let name = common?["name"]?.stringValue ?? "App \(appID)"
        let oslist = (common?["oslist"]?.stringValue ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return SteamAppInfo(appID: appID, name: name, oslist: oslist, type: common?["type"]?.stringValue)
    }

    /// Parse many apps' blocks (one combined `app_info_print` dump) for the given known IDs.
    public static func parseAll(appInfoOutput output: String, appIDs: [Int]) -> [SteamAppInfo] {
        appIDs.compactMap { parse(appInfoOutput: output, appID: $0) }
    }

    /// Extract the brace-balanced `"<key>" { … }` block from `text` (skipping SteamCMD's log preamble
    /// and trailing chatter). Brace-counts; a `{`/`}` inside a quoted string is rare in app metadata.
    static func extractBlock(_ text: String, key: String) -> String? {
        guard let keyRange = text.range(of: "\"\(key)\""),
              let braceStart = text.range(of: "{", range: keyRange.upperBound..<text.endIndex)
        else { return nil }
        var depth = 0
        var idx = braceStart.lowerBound
        while idx < text.endIndex {
            switch text[idx] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    let end = text.index(after: idx)
                    return "\"\(key)\" " + String(text[braceStart.lowerBound..<end])
                }
            default: break
            }
            idx = text.index(after: idx)
        }
        return nil
    }
}
