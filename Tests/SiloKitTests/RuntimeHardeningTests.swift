import Foundation
import Testing
@testable import SiloKit

@Suite("RuntimeHardening.deQuarantine")
struct RuntimeHardeningTests {

    @Test("de-quarantines recursively and never re-signs (x86_64 runs unsigned; signature preserved)")
    func deQuarantinesOnly() async throws {
        let dir = URL(fileURLWithPath: "/runtime/wine")
        let fake = FakeProcessRunner()
        await deQuarantine(dir, using: fake)
        // Exactly one call — `xattr -dr com.apple.quarantine` — and NEVER codesign (which can't sign a
        // non-bundle tree and would clobber Apple's D3DMetal signature).
        #expect(fake.invocations.map { $0.executable.lastPathComponent } == ["xattr"])
        #expect(fake.invocations.first?.arguments == ["-dr", "com.apple.quarantine", dir.path])
    }

    @Test("issue(for:) names a de-quarantine failure and is nil on success")
    func hardeningOutcome() async throws {
        let dir = URL(fileURLWithPath: "/runtime/wine-cx")

        let clean = FakeProcessRunner()
        let ok = await deQuarantine(dir, using: clean)
        #expect(ok == HardeningOutcome(quarantineCleared: true))
        #expect(ok.issue(for: dir) == nil)

        let xattrFails = FakeProcessRunner()
        xattrFails.queueResult(ProcessResult(exitCode: 1))     // xattr fails
        let outcome = await deQuarantine(dir, using: xattrFails)
        #expect(!outcome.quarantineCleared)
        let issue = try #require(outcome.issue(for: dir))
        #expect(issue.contains("quarantine") && issue.contains("wine-cx"))
    }
}
