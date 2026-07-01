import Foundation
import Testing
@testable import SiloKit

@Suite("RuntimeHardening.deQuarantine")
struct RuntimeHardeningTests {

    @Test("always de-quarantines; re-signs only when asked")
    func deQuarantineReSign() async throws {
        let dir = URL(fileURLWithPath: "/runtime/wine")

        let withSign = FakeProcessRunner()
        await deQuarantine(dir, reSign: true, using: withSign)
        #expect(withSign.invocations.map { $0.executable.lastPathComponent } == ["xattr", "codesign"])
        #expect(withSign.invocations.first?.arguments.contains("com.apple.quarantine") == true)
        #expect(withSign.invocations.last?.arguments.contains("--sign") == true)

        let noSign = FakeProcessRunner()
        await deQuarantine(dir, reSign: false, using: noSign)
        #expect(noSign.invocations.map { $0.executable.lastPathComponent } == ["xattr"])   // no codesign
    }

    @Test("the outcome reports what failed; issue(for:) names it (nil when clean)")
    func hardeningOutcome() async throws {
        let dir = URL(fileURLWithPath: "/runtime/wine-cx")

        let clean = FakeProcessRunner()
        let ok = await deQuarantine(dir, reSign: true, using: clean)
        #expect(ok == HardeningOutcome(quarantineCleared: true, signed: true))
        #expect(ok.issue(for: dir) == nil)

        let xattrFails = FakeProcessRunner()
        xattrFails.queueResult(ProcessResult(exitCode: 1))     // xattr fails; codesign default-succeeds
        let outcome = await deQuarantine(dir, reSign: true, using: xattrFails)
        #expect(!outcome.quarantineCleared && outcome.signed == true)
        let issue = try #require(outcome.issue(for: dir))
        #expect(issue.contains("quarantine") && issue.contains("wine-cx"))

        let signFails = FakeProcessRunner()
        signFails.queueResult(ProcessResult(exitCode: 0))      // xattr ok
        signFails.queueResult(ProcessResult(exitCode: 1))      // codesign fails
        let signOutcome = await deQuarantine(dir, reSign: true, using: signFails)
        #expect(signOutcome.issue(for: dir)?.contains("re-sign") == true)

        // reSign: false → signing "not attempted" is NOT an issue.
        let noSign = FakeProcessRunner()
        let noSignOutcome = await deQuarantine(dir, reSign: false, using: noSign)
        #expect(noSignOutcome.signed == nil && noSignOutcome.issue(for: dir) == nil)
    }
}
