import Foundation

/// Parses a Valve KeyValues token stream into a `KVNode` tree.
///
/// Grammar (recursive): an object is a sequence of `key value` pairs, where `value` is either a
/// string leaf or a `{ ... }` nested object. The top level is itself an object (e.g. a single
/// `"AppState" { ... }` pair for an appmanifest).
public struct KeyValuesParser: Sendable {
    public init() {}

    public enum ParseError: Error, Equatable {
        case unexpectedToken
        case unexpectedEOF
        case missingValue(key: String)
        case unexpectedCloseBrace
    }

    /// Convenience: tokenize then parse.
    public func parse(text: String) throws -> KVNode {
        let tokens = try ACFTokenizer(text).tokenize()
        return try parse(tokens)
    }

    public func parse(_ tokens: [KVToken]) throws -> KVNode {
        var index = 0
        let pairs = try parseObjectBody(tokens, &index, topLevel: true)
        return .object(pairs)
    }

    /// Parses pairs until a `}` (nested) or end of input (top level).
    /// On return for a nested object, `index` points AT the closing `}` (caller consumes it).
    private func parseObjectBody(
        _ tokens: [KVToken], _ index: inout Int, topLevel: Bool
    ) throws -> [KVPair] {
        var pairs: [KVPair] = []

        while index < tokens.count {
            switch tokens[index] {
            case .closeBrace:
                if topLevel { throw ParseError.unexpectedCloseBrace }
                return pairs   // leave the `}` for the caller to consume

            case .openBrace:
                throw ParseError.unexpectedToken   // brace where a key was expected

            case .string(let key):
                index += 1
                guard index < tokens.count else { throw ParseError.missingValue(key: key) }

                switch tokens[index] {
                case .openBrace:
                    index += 1   // consume `{`
                    let body = try parseObjectBody(tokens, &index, topLevel: false)
                    guard index < tokens.count, tokens[index] == .closeBrace else {
                        throw ParseError.unexpectedEOF
                    }
                    index += 1   // consume `}`
                    pairs.append(KVPair(key, .object(body)))

                case .string(let value):
                    index += 1
                    pairs.append(KVPair(key, .leaf(value)))

                case .closeBrace:
                    throw ParseError.missingValue(key: key)
                }
            }
        }

        if !topLevel { throw ParseError.unexpectedEOF }   // ran out before closing `}`
        return pairs
    }
}
