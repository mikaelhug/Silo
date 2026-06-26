import Foundation

/// Decodes `libraryfolders.vdf` into `[LibraryFolder]`.
///
/// Supports both the modern object format (`"0" { "path" ... "apps" { ... } }`) and the legacy
/// leaf format (`"0" "/path"`). Non-numeric sibling keys (meta fields like `ContentStatsID`) are
/// skipped.
public struct LibraryFoldersDecoder: Sendable {
    public init() {}

    public enum DecodeError: Error, Equatable {
        case missingRoot
    }

    public func decode(text: String) throws -> [LibraryFolder] {
        try decode(KeyValuesParser().parse(text: text))
    }

    public func decode(_ node: KVNode) throws -> [LibraryFolder] {
        guard let root = node["libraryfolders"] else { throw DecodeError.missingRoot }

        var folders: [LibraryFolder] = []
        for pair in root.pairs {
            guard Int(pair.key) != nil else { continue }   // only numeric folder entries

            switch pair.value {
            case .leaf(let pathString):
                folders.append(LibraryFolder(path: URL(fileURLWithPath: pathString)))

            case .object:
                guard let pathString = pair.value["path"]?.stringValue else { continue }
                let rawLabel = pair.value["label"]?.stringValue
                let label = (rawLabel?.isEmpty ?? true) ? nil : rawLabel
                let appIDs = (pair.value["apps"]?.pairs ?? []).compactMap { Int($0.key) }
                folders.append(
                    LibraryFolder(path: URL(fileURLWithPath: pathString), label: label, appIDs: appIDs)
                )
            }
        }
        return folders
    }
}
