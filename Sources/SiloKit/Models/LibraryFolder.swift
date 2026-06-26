import Foundation

/// A Steam library folder parsed from `libraryfolders.vdf`.
public struct LibraryFolder: Codable, Sendable, Hashable {
    /// Library root (the folder that contains `steamapps/`).
    public let path: URL
    public let label: String?
    public let appIDs: [Int]

    public init(path: URL, label: String? = nil, appIDs: [Int] = []) {
        self.path = path
        self.label = label
        self.appIDs = appIDs
    }

    /// The `steamapps` directory inside this library folder.
    public var steamappsURL: URL {
        path.appendingPathComponent("steamapps", isDirectory: true)
    }
}
