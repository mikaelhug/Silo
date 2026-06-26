import Foundation

/// Reads the set of owned/known Steam app IDs from a logged-in account's `localconfig.vdf`
/// (`<steamRoot>/userdata/<accountID>/config/localconfig.vdf`), unioned across all local accounts.
public struct OwnedAppsReader: Sendable {
    public init() {}

    public func ownedAppIDs(steamRoot: URL) -> [Int] {
        let fileManager = FileManager.default
        let userdata = steamRoot.appendingPathComponent("userdata", isDirectory: true)
        guard let accounts = try? fileManager.contentsOfDirectory(
            at: userdata, includingPropertiesForKeys: nil) else { return [] }

        let parser = KeyValuesParser()
        var ids = Set<Int>()
        for account in accounts {
            let config = account.appendingPathComponent("config/localconfig.vdf")
            guard let text = try? String(contentsOf: config, encoding: .utf8),
                  let root = try? parser.parse(text: text) else { continue }
            // UserLocalConfigStore → Software → Valve → Steam → apps  (all case-insensitive)
            let apps = root["UserLocalConfigStore"]?["Software"]?["Valve"]?["Steam"]?["apps"]
            for pair in apps?.pairs ?? [] {
                if let id = Int(pair.key) { ids.insert(id) }
            }
        }
        return ids.sorted()
    }
}
