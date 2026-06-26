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
        let apps = try tmp.makeDir("apps")
        let cfg = resolver.autodetect(homeDirectory: home, applicationsDirectory: apps)
        #expect(cfg.detectedSource == .none)
        #expect(!cfg.isWineConfigured)
    }

    @Test("Detects Whisky and its GPTK/DXVK lib dirs")
    func whisky() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let home = try tmp.makeDir("home")
        let apps = try tmp.makeDir("apps")
        let base = "home/Library/Application Support/com.isaacmarovitz.Whisky/Libraries"
        try tmp.write("\(base)/Wine/bin/wine64", "#!/bin/sh")
        try tmp.makeDir("\(base)/GPTK")
        try tmp.makeDir("\(base)/DXVK")

        let cfg = resolver.autodetect(homeDirectory: home, applicationsDirectory: apps)
        #expect(cfg.detectedSource == .whisky)
        #expect(cfg.wineBinaryPath?.lastPathComponent == "wine64")
        #expect(cfg.gptkLibDirPath?.lastPathComponent == "GPTK")
        #expect(cfg.dxvkDLLDirPath?.lastPathComponent == "DXVK")
    }

    @Test("Detects CrossOver and uses it as the crossover wine")
    func crossover() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let home = try tmp.makeDir("home")
        let apps = try tmp.makeDir("apps")
        try tmp.write("apps/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine64", "#!/bin/sh")

        let cfg = resolver.autodetect(homeDirectory: home, applicationsDirectory: apps)
        #expect(cfg.detectedSource == .crossover)
        #expect(cfg.crossoverWinePath?.lastPathComponent == "wine64")
        #expect(cfg.wineBinary(for: .crossover)?.lastPathComponent == "wine64")
    }

    @Test("Whisky takes priority over CrossOver when both are present")
    func priority() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let home = try tmp.makeDir("home")
        let apps = try tmp.makeDir("apps")
        try tmp.write("home/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin/wine64", "x")
        try tmp.write("apps/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine64", "x")

        #expect(resolver.autodetect(homeDirectory: home, applicationsDirectory: apps).detectedSource == .whisky)
    }
}
