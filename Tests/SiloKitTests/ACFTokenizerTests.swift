import Testing
@testable import SiloKit

@Suite("ACFTokenizer")
struct ACFTokenizerTests {

    @Test("Tokenizes quoted key/value pairs")
    func quotedPairs() throws {
        let tokens = try ACFTokenizer(#""appid"   "220""#).tokenize()
        #expect(tokens == [.string("appid"), .string("220")])
    }

    @Test("Tokenizes braces and nesting")
    func braces() throws {
        let tokens = try ACFTokenizer(#""AppState" { "appid" "220" }"#).tokenize()
        #expect(tokens == [
            .string("AppState"), .openBrace,
            .string("appid"), .string("220"),
            .closeBrace,
        ])
    }

    @Test("Skips // line comments")
    func comments() throws {
        let text = """
        // leading comment
        "appid" "220" // trailing comment
        "name" "HL2"
        """
        let tokens = try ACFTokenizer(text).tokenize()
        #expect(tokens == [
            .string("appid"), .string("220"),
            .string("name"), .string("HL2"),
        ])
    }

    @Test("Processes escape sequences inside quoted strings")
    func escapes() throws {
        // Windows-style path with doubled backslashes + an escaped quote + newline.
        let tokens = try ACFTokenizer(#""path" "C:\\Program Files\\Steam" "q" "a\"b" "nl" "x\ny""#).tokenize()
        #expect(tokens == [
            .string("path"), .string(#"C:\Program Files\Steam"#),
            .string("q"), .string(#"a"b"#),
            .string("nl"), .string("x\ny"),
        ])
    }

    @Test("Reads bare (unquoted) tokens")
    func bareTokens() throws {
        let tokens = try ACFTokenizer("appid 220 { name HL2 }").tokenize()
        #expect(tokens == [
            .string("appid"), .string("220"),
            .openBrace, .string("name"), .string("HL2"), .closeBrace,
        ])
    }

    @Test("Throws on an unterminated string with the right line number")
    func unterminated() {
        let text = """
        "appid" "220"
        "name" "Half-Life
        """
        #expect(throws: ACFTokenizer.TokenizerError.unterminatedString(line: 2)) {
            try ACFTokenizer(text).tokenize()
        }
    }

    @Test("Empty input yields no tokens")
    func empty() throws {
        #expect(try ACFTokenizer("   \n\t  ").tokenize().isEmpty)
    }
}
