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
}
