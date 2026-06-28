import Foundation

/// Decodes a parsed `appmanifest_*.acf` (`KVNode`) into a `SteamApp`.
public struct AppManifestDecoder: Sendable {
    public init() {}

    public enum DecodeError: Error, Equatable {
        case missingRoot                                  // no top-level "AppState"
        case missingField(String)
        case invalidInteger(field: String, value: String)
        case invalidInstallDir(String)                    // a path-escaping/empty installdir
    }

    /// Convenience: parse text then decode.
    public func decode(text: String, libraryPath: URL) throws -> SteamApp {
        let node = try KeyValuesParser().parse(text: text)
        return try decode(node, libraryPath: libraryPath)
    }

    public func decode(_ node: KVNode, libraryPath: URL) throws -> SteamApp {
        guard let state = node["AppState"] else { throw DecodeError.missingRoot }
        return SteamApp(
            appID: try requireInt(state, "appid"),
            name: try requireString(state, "name"),
            installDir: try requireInstallDir(state),
            stateFlags: StateFlags(rawValue: optInt(state, "StateFlags") ?? 0),
            sizeOnDisk: optInt64(state, "SizeOnDisk") ?? 0,
            bytesDownloaded: optInt64(state, "BytesDownloaded"),
            bytesToDownload: optInt64(state, "BytesToDownload"),
            buildID: optInt(state, "buildid"),
            lastUpdated: optDate(state, "LastUpdated"),
            libraryPath: libraryPath
        )
    }

    // MARK: - Field helpers

    private func requireString(_ node: KVNode, _ key: String) throws -> String {
        guard let value = node[key]?.stringValue else { throw DecodeError.missingField(key) }
        return value
    }

    /// `installdir` is a single directory name under `steamapps/common`, where the game exe and
    /// `steam_appid.txt` get resolved. A hostile manifest could set it to `../…` or an absolute path to
    /// escape that dir, so reject anything that isn't a flat component (empty, `/`, `\`, `.`, `..`).
    private func requireInstallDir(_ node: KVNode) throws -> String {
        let value = try requireString(node, "installdir")
        guard !value.isEmpty, !value.contains("/"), !value.contains("\\"),
              value != ".", value != ".." else {
            throw DecodeError.invalidInstallDir(value)
        }
        return value
    }

    private func requireInt(_ node: KVNode, _ key: String) throws -> Int {
        let string = try requireString(node, key)
        guard let value = Int(string) else {
            throw DecodeError.invalidInteger(field: key, value: string)
        }
        return value
    }

    private func opt<T>(_ node: KVNode, _ key: String, _ parse: (String) -> T?) -> T? {
        node[key]?.stringValue.flatMap(parse)
    }

    private func optInt(_ node: KVNode, _ key: String) -> Int? { opt(node, key, Int.init) }

    private func optInt64(_ node: KVNode, _ key: String) -> Int64? { opt(node, key, Int64.init) }

    private func optDate(_ node: KVNode, _ key: String) -> Date? {
        guard let string = node[key]?.stringValue,
              let epoch = TimeInterval(string), epoch > 0 else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }
}
