import Foundation

/// A lexical token in the Valve KeyValues grammar.
public enum KVToken: Equatable, Sendable {
    case string(String)   // a quoted or bare key/value
    case openBrace
    case closeBrace
}

/// Tokenizes Valve KeyValues text (`appmanifest_*.acf`, `*.vdf`) into a flat token stream.
///
/// Handles: quoted strings with `\\ \" \n \t \r` escapes, bare (unquoted) tokens, `{`/`}`,
/// `//` line comments, and tracks line numbers for error reporting.
public struct ACFTokenizer: Sendable {
    private let chars: [Character]

    public init(_ text: String) {
        self.chars = Array(text)
    }

    public enum TokenizerError: Error, Equatable {
        case unterminatedString(line: Int)
    }

    public func tokenize() throws -> [KVToken] {
        var tokens: [KVToken] = []
        var i = 0
        var line = 1
        let n = chars.count

        while i < n {
            let c = chars[i]
            switch c {
            case "\n":
                line += 1
                i += 1
            case " ", "\t", "\r":
                i += 1
            case "{":
                tokens.append(.openBrace)
                i += 1
            case "}":
                tokens.append(.closeBrace)
                i += 1
            case "/" where i + 1 < n && chars[i + 1] == "/":
                i += 2
                while i < n && chars[i] != "\n" { i += 1 }
            case "\"":
                let result = try readQuotedString(from: i, line: line)
                tokens.append(.string(result.value))
                i = result.nextIndex
                line = result.line
            default:
                let result = readBareToken(from: i)
                tokens.append(.string(result.value))
                i = result.nextIndex
            }
        }
        return tokens
    }

    private func readQuotedString(
        from start: Int, line startLine: Int
    ) throws -> (value: String, nextIndex: Int, line: Int) {
        var i = start + 1   // skip opening quote
        var line = startLine
        var out = ""
        let n = chars.count

        while i < n {
            let c = chars[i]
            if c == "\\" {
                guard i + 1 < n else { throw TokenizerError.unterminatedString(line: line) }
                let next = chars[i + 1]
                switch next {
                case "\\": out.append("\\")
                case "\"": out.append("\"")
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                default: out.append(next)
                }
                if next == "\n" { line += 1 }
                i += 2
            } else if c == "\"" {
                return (out, i + 1, line)   // consume closing quote
            } else {
                if c == "\n" { line += 1 }
                out.append(c)
                i += 1
            }
        }
        throw TokenizerError.unterminatedString(line: line)
    }

    private func readBareToken(from start: Int) -> (value: String, nextIndex: Int) {
        var i = start
        var out = ""
        let n = chars.count

        while i < n {
            let c = chars[i]
            if c == " " || c == "\t" || c == "\n" || c == "\r"
                || c == "{" || c == "}" || c == "\"" {
                break
            }
            if c == "/" && i + 1 < n && chars[i + 1] == "/" { break }   // comment start
            out.append(c)
            i += 1
        }
        return (out, i)
    }
}
