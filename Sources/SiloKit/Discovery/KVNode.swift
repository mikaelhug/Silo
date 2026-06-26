import Foundation

/// One key/value entry in a Valve KeyValues object. A struct (not a tuple) so `KVNode` can
/// synthesize `Equatable` — tuples cannot conform to protocols.
public struct KVPair: Sendable, Equatable {
    public let key: String
    public let value: KVNode
    public init(_ key: String, _ value: KVNode) {
        self.key = key
        self.value = value
    }
}

/// A parsed Valve KeyValues tree (the format used by `appmanifest_*.acf` and `libraryfolders.vdf`).
///
/// Order is preserved and duplicate keys are allowed, matching Valve's format. Key lookup is
/// case-insensitive (Valve keys are case-insensitive).
public indirect enum KVNode: Sendable, Equatable {
    case leaf(String)
    case object([KVPair])

    /// The string payload if this node is a leaf, else `nil`.
    public var stringValue: String? {
        if case let .leaf(value) = self { return value }
        return nil
    }

    /// The child pairs if this node is an object, else `[]`.
    public var pairs: [KVPair] {
        if case let .object(pairs) = self { return pairs }
        return []
    }

    /// First child value matching `key` (case-insensitive). `nil` for leaves or no match.
    public subscript(_ key: String) -> KVNode? {
        guard case let .object(pairs) = self else { return nil }
        return pairs.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    /// Every child value matching `key` (case-insensitive), in document order.
    public func all(_ key: String) -> [KVNode] {
        pairs.filter { $0.key.caseInsensitiveCompare(key) == .orderedSame }.map(\.value)
    }
}
