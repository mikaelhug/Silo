import Foundation
import Testing
@testable import SiloKit

@Suite("SteamStoreClient parsing")
struct SteamStoreClientTests {

    @Test("Parses description, developer, genres, art from the appdetails response")
    func parses() {
        let json = """
        {"220":{"success":true,"data":{
          "name":"Half-Life 2",
          "short_description":"1998. HL.",
          "developers":["Valve"],
          "publishers":["Valve"],
          "genres":[{"id":"1","description":"Action"},{"id":"25","description":"Adventure"}],
          "header_image":"https://cdn.example/220/header.jpg",
          "release_date":{"coming_soon":false,"date":"16 Nov, 2004"}
        }}}
        """
        let d = try! #require(SteamStoreClient.parse(Data(json.utf8), appID: 220))
        #expect(d.shortDescription == "1998. HL.")
        #expect(d.developers == ["Valve"])
        #expect(d.genres == ["Action", "Adventure"])
        #expect(d.headerImageURL?.absoluteString == "https://cdn.example/220/header.jpg")
        #expect(d.releaseDate == "16 Nov, 2004")
    }

    @Test("Returns nil when the app isn't found (success:false)")
    func notFound() {
        let json = #"{"999":{"success":false}}"#
        #expect(SteamStoreClient.parse(Data(json.utf8), appID: 999) == nil)
    }
}
