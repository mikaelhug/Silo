import Foundation
import Testing
@testable import SiloKit

@Suite("User-facing error text")
struct ErrorMessagesTests {

    /// Every first-run failure must read as a sentence, never as
    /// "The operation couldn't be completed. (SiloKit.… error 4.)" — which is what a bare Swift enum
    /// produces through `(error as NSError).localizedDescription`, the formatter every VM uses.
    @Test("the errors a first run actually hits are human-readable, not Cocoa gibberish")
    func firstRunErrorsAreReadable() {
        let errors: [any Error] = [
            RuntimeManager.RuntimeError.badResponse(403),
            RuntimeManager.RuntimeError.downloadFailed(404),
            RuntimeManager.RuntimeError.extractionFailed(2),
            RuntimeManager.RuntimeError.checksumMismatch(expected: "a", actual: "b"),
            RuntimeManager.RuntimeError.checksumUnavailable,
            GPTKImporter.ImportError.nestedDMGNotFound,
            GPTKImporter.ImportError.redistNotFound,
            SteamBottle.BottleError.winebootFailed(1),
            SteamBottle.BottleError.installerDownloadFailed(500),
            SteamBottle.BottleError.steamInstallFailed(1602),
            SteamBottle.BottleError.componentCancelled(.coreFonts),
        ]
        for error in errors {
            let text = (error as NSError).localizedDescription
            #expect(!text.contains("operation couldn't be completed"), "gibberish for \(error)")
            #expect(!text.contains("SiloKit."), "leaks a type name for \(error)")
            #expect(text.count > 15 && text.hasSuffix("."), "not a sentence for \(error): \(text)")
        }
        // The diagnostic detail the case carries is preserved, not swallowed.
        #expect((RuntimeManager.RuntimeError.badResponse(403) as NSError)
            .localizedDescription.contains("403"))
    }
}
