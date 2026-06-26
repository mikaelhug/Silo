import Testing
@testable import SiloKit

@Suite("KeyValuesParser")
struct KeyValuesParserTests {
    let parser = KeyValuesParser()

    @Test("Parses a nested appmanifest-shaped document")
    func nested() throws {
        let text = """
        "AppState"
        {
            "appid"      "220"
            "name"       "Half-Life 2"
            "installdir" "Half-Life 2"
            "UserConfig"
            {
                "language" "english"
            }
        }
        """
        let root = try parser.parse(text: text)
        let app = try #require(root["AppState"])
        #expect(app["appid"]?.stringValue == "220")
        #expect(app["name"]?.stringValue == "Half-Life 2")
        #expect(app["UserConfig"]?["language"]?.stringValue == "english")
    }

    @Test("Key lookup is case-insensitive")
    func caseInsensitive() throws {
        let root = try parser.parse(text: #""AppState" { "AppID" "10" }"#)
        #expect(root["appstate"]?["appid"]?.stringValue == "10")
    }

    @Test("Preserves duplicate keys in order")
    func duplicates() throws {
        let root = try parser.parse(text: #""r" { "app" "1" "app" "2" "app" "3" }"#)
        let r = try #require(root["r"])
        #expect(r.all("app").compactMap(\.stringValue) == ["1", "2", "3"])
    }

    @Test("Handles empty objects")
    func emptyObject() throws {
        let root = try parser.parse(text: #""r" { }"#)
        #expect(root["r"]?.pairs.isEmpty == true)
    }

    @Test("Throws missingValue when a key has no value")
    func missingValue() {
        #expect(throws: KeyValuesParser.ParseError.missingValue(key: "appid")) {
            try parser.parse(text: #""r" { "appid" }"#)
        }
    }

    @Test("Throws on an unbalanced closing brace")
    func unexpectedClose() {
        #expect(throws: KeyValuesParser.ParseError.unexpectedCloseBrace) {
            try parser.parse(text: "}")
        }
    }

    @Test("Throws unexpectedEOF on an unclosed object")
    func unclosed() {
        #expect(throws: KeyValuesParser.ParseError.unexpectedEOF) {
            try parser.parse(text: #""r" { "appid" "220""#)
        }
    }
}
