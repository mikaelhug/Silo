import Foundation
import Testing
@testable import SiloKit

@Suite("Versions ↔ versions.env")
struct VersionsTests {

    /// Parse `KEY=VALUE` out of versions.env (located relative to this source file → repo root).
    private func envValue(_ key: String) throws -> String? {
        let repoRoot = URL(fileURLWithPath: #filePath)   // Tests/SiloKitTests/VersionsTests.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: repoRoot.appendingPathComponent("versions.env"), encoding: .utf8)
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), trimmed.hasPrefix("\(key)=") else { continue }
            return String(trimmed.dropFirst(key.count + 1))
        }
        return nil
    }

    /// Guards against editing versions.env without re-running Scripts/gen-versions.sh — the generated
    /// `Versions.swift` is committed, so it can drift out of sync silently otherwise.
    @Test("Versions.swift mirrors versions.env (run Scripts/gen-versions.sh after editing it)")
    func versionsInSync() throws {
        #expect(try envValue("SILO_VERSION") == Versions.silo)
        #expect(try envValue("SILO_GITHUB_REPO") == Versions.githubRepo)
        #expect(try envValue("CROSSOVER_VERSION") == Versions.crossoverVersion)
    }

    @Test("Silo's public constants are sourced from Versions")
    func siloConstantsSourced() {
        #expect(Silo.version == Versions.silo)
        #expect(Silo.updateRepo == Versions.githubRepo)
        #expect(Silo.wineRepo == Versions.githubRepo)
    }
}
