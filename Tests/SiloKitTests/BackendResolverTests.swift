import Foundation
import Testing
@testable import SiloKit

@Suite("BackendResolver")
struct BackendResolverTests {
    let resolver = BackendResolver()

    @Test("Returns .none on a clean machine (no backend installed)")
    func allAbsent() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let home = try tmp.makeDir("home")
        let cfg = resolver.autodetect(homeDirectory: home)
        #expect(cfg.detectedSource == .none)
        #expect(!cfg.isWineConfigured)
    }

    @Test("Detects Whisky and its GPTK lib dir")
    func whisky() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let home = try tmp.makeDir("home")
        let base = "home/Library/Application Support/com.isaacmarovitz.Whisky/Libraries"
        try tmp.write("\(base)/Wine/bin/wine64", "#!/bin/sh")
        try tmp.makeDir("\(base)/GPTK")

        let cfg = resolver.autodetect(homeDirectory: home)
        #expect(cfg.detectedSource == .whisky)
        #expect(cfg.wineBinaryPath?.lastPathComponent == "wine64")
        #expect(cfg.gptkLibDirPath?.lastPathComponent == "GPTK")
    }

    @Test("Whisky takes priority over Kegworks when both are present")
    func priority() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let home = try tmp.makeDir("home")
        try tmp.write("home/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin/wine64", "x")
        try tmp.write("home/Library/Application Support/Kegworks/Libraries/Wine/bin/wine64", "x")

        #expect(resolver.autodetect(homeDirectory: home).detectedSource == .whisky)
    }
}
