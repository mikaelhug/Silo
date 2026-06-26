import Foundation

/// Locates files committed under `Tests/SiloKitTests/Fixtures` (copied verbatim into the test
/// bundle via `.copy("Fixtures")` in Package.swift).
enum FixtureLoader {
    /// Root of the copied `Fixtures` directory inside the test bundle.
    static var root: URL {
        let base = Bundle.module.resourceURL ?? Bundle.module.bundleURL
        return base.appendingPathComponent("Fixtures", isDirectory: true)
    }

    /// URL for a fixture by its name (including extension), supporting subpaths like `FakePrefix/...`.
    static func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    /// UTF-8 contents of a text fixture.
    static func text(_ relativePath: String) throws -> String {
        try String(contentsOf: url(relativePath), encoding: .utf8)
    }
}
