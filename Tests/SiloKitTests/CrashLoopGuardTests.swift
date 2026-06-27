import Foundation
import Testing
@testable import SiloKit

@Suite("CrashLoopGuard")
struct CrashLoopGuardTests {

    @Test("Kills the bottle when a winedbg storm is detected")
    func killsOnStorm() async {
        let fake = FakeProcessRunner()
        fake.processCountValue = 50                       // simulate a winedbg storm
        let sut = CrashLoopGuard(runner: fake)
        await sut.monitor(
            wine: URL(fileURLWithPath: "/w/bin/wine"), bottle: URL(fileURLWithPath: "/b"),
            threshold: 30, interval: .milliseconds(2), maxChecks: 5)

        let kill = fake.invocations.last
        #expect(kill?.executable.lastPathComponent == "wineserver")
        #expect(kill?.arguments == ["-k"])
        #expect(kill?.environment["WINEPREFIX"] == "/b")
        // Stops at the first storm detection — exactly one kill.
        #expect(fake.invocations.filter { $0.arguments == ["-k"] }.count == 1)
    }

    @Test("Does nothing while the process count stays below threshold")
    func calmIsNoOp() async {
        let fake = FakeProcessRunner()
        fake.processCountValue = 3
        let sut = CrashLoopGuard(runner: fake)
        await sut.monitor(
            wine: URL(fileURLWithPath: "/w/bin/wine"), bottle: URL(fileURLWithPath: "/b"),
            threshold: 30, interval: .milliseconds(2), maxChecks: 3)
        #expect(!fake.invocations.contains { $0.arguments == ["-k"] })
    }
}
