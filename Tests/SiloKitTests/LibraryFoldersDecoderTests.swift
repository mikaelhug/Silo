import Foundation
import Testing
@testable import SiloKit

@Suite("LibraryFoldersDecoder")
struct LibraryFoldersDecoderTests {
    let decoder = LibraryFoldersDecoder()

    @Test("Decodes the modern object format with apps + labels")
    func modernFormat() throws {
        let folders = try decoder.decode(text: FixtureLoader.text("libraryfolders.vdf"))
        #expect(folders.count == 2)

        #expect(folders[0].path.lastPathComponent == "Steam")
        #expect(folders[0].label == nil)               // empty label normalizes to nil
        #expect(folders[0].appIDs == [220, 570])
        #expect(folders[0].steamappsURL.path.hasSuffix("/Steam/steamapps"))

        #expect(folders[1].label == "Games SSD")
        #expect(folders[1].appIDs == [440])
    }

    @Test("Decodes the legacy leaf format")
    func legacyFormat() throws {
        let folders = try decoder.decode(text: #""libraryfolders" { "0" "/a/Steam" "1" "/b/Lib" }"#)
        #expect(folders.map(\.path.path) == ["/a/Steam", "/b/Lib"])
        #expect(folders.allSatisfy { $0.appIDs.isEmpty })
    }

    @Test("Skips non-numeric meta keys")
    func skipsMeta() throws {
        let text = #""libraryfolders" { "ContentStatsID" "123" "0" { "path" "/x" } }"#
        let folders = try decoder.decode(text: text)
        #expect(folders.count == 1)
        #expect(folders[0].path.path == "/x")
    }

    @Test("Throws missingRoot for the wrong top-level key")
    func missingRoot() {
        #expect(throws: LibraryFoldersDecoder.DecodeError.missingRoot) {
            try decoder.decode(text: #""other" { "0" { "path" "/x" } }"#)
        }
    }

    @Test("Skips a numeric folder entry missing its path key, keeps valid siblings")
    func skipsObjectEntryWithoutPath() throws {
        let text = #""libraryfolders" { "0" { "label" "NoPath" "apps" { "10" "1" } } "1" { "path" "/good" "label" "Good" "apps" { "440" "1" } } }"#
        let folders = try decoder.decode(text: text)
        #expect(folders.count == 1)                         // path-less "0" dropped, not crashed/defaulted
        #expect(folders[0].path.path == "/good")            // surviving sibling decodes correctly
        #expect(folders[0].label == "Good")
        #expect(folders[0].appIDs == [440])
    }
}
