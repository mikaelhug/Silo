import Foundation
import Testing
@testable import SiloKit

@Suite("WinePrefixProvisioner")
struct WinePrefixProvisionerTests {

    @Test("provision boots a fresh prefix and is a no-op once booted")
    func provisionIdempotent() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let fake = FakeProcessRunner()
        let prefix = tmp.url.appendingPathComponent("Bottle")
        let provisioner = WinePrefixProvisioner(runner: fake)
        #expect(!provisioner.isProvisioned(prefix))

        // wineboot --init: simulate Wine writing system.reg + drive_c.
        fake.onRun = { inv in
            guard inv.arguments == ["wineboot", "--init"] else { return }
            let layout = PrefixLayout(prefix: prefix)
            try? FileManager.default.createDirectory(at: layout.driveC, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: layout.systemReg.path, contents: Data())
        }

        try await provisioner.provision(prefix: prefix, wine: URL(fileURLWithPath: "/w/wine64"))
        #expect(provisioner.isProvisioned(prefix))
        #expect(fake.invocations.filter { $0.arguments == ["wineboot", "--init"] }.count == 1)
        // The boot server is settled (wineserver -k) so the first launch right after doesn't race it.
        #expect(fake.invocations.filter { $0.arguments == ["-k"] }.count == 1)

        // Already booted → second call must NOT wineboot (or re-kill) again.
        try await provisioner.provision(prefix: prefix, wine: URL(fileURLWithPath: "/w/wine64"))
        #expect(fake.invocations.filter { $0.arguments == ["wineboot", "--init"] }.count == 1)
        #expect(fake.invocations.filter { $0.arguments == ["-k"] }.count == 1)
    }

    @Test("provision throws wineNotConfigured on nil wine, winebootFailed on non-zero")
    func provisionErrors() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let fake = FakeProcessRunner()
        let prefix = tmp.url.appendingPathComponent("Bottle")
        let provisioner = WinePrefixProvisioner(runner: fake)

        await #expect(throws: WinePrefixProvisioner.ProvisionError.wineNotConfigured) {
            try await provisioner.provision(prefix: prefix, wine: nil)
        }
        fake.queueResult(ProcessResult(exitCode: 7))
        await #expect(throws: WinePrefixProvisioner.ProvisionError.winebootFailed(7)) {
            try await provisioner.provision(prefix: prefix, wine: URL(fileURLWithPath: "/w/wine64"))
        }
    }
}
