import Foundation
import Testing
@testable import SiloKit

@Suite("PrefixProvisioner")
struct PrefixProvisionerTests {

    private func makeProvisioner(_ fake: FakeProcessRunner, _ tmp: TempDir) -> PrefixProvisioner {
        PrefixProvisioner(runner: fake, paths: AppPaths(supportDir: tmp.url.appendingPathComponent("Silo")))
    }

    /// Hook that simulates wineboot creating drive_c + system.reg in the prefix.
    private func bootHook(prefix: URL) -> @Sendable (FakeProcessRunner.Invocation) -> Void {
        return { _ in
            let layout = PrefixLayout(prefix: prefix)
            try? FileManager.default.createDirectory(at: layout.driveC, withIntermediateDirectories: true)
            try? "WINE REG".write(to: layout.systemReg, atomically: true, encoding: .utf8)
        }
    }

    @Test("Provisions an unbooted prefix via wineboot with the isolated WINEPREFIX")
    func provisions() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let fake = FakeProcessRunner()
        let provisioner = makeProvisioner(fake, tmp)
        let prefix = provisioner.prefixURL(forAppID: 220)
        fake.onRun = bootHook(prefix: prefix)

        #expect(await provisioner.isProvisioned(appID: 220) == false)

        let wine = URL(fileURLWithPath: "/runtimes/gptk/bin/wine64")
        let result = try await provisioner.provision(appID: 220, wineBinary: wine)

        #expect(result == prefix)
        #expect(fake.invocations.count == 1)
        #expect(fake.lastInvocation?.executable == wine)
        #expect(fake.lastInvocation?.arguments == ["wineboot", "--init"])
        #expect(fake.lastInvocation?.environment["WINEPREFIX"] == prefix.path)
        #expect(await provisioner.isProvisioned(appID: 220))
    }

    @Test("Is idempotent — a booted prefix is not re-booted")
    func idempotent() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let fake = FakeProcessRunner()
        let provisioner = makeProvisioner(fake, tmp)
        fake.onRun = bootHook(prefix: provisioner.prefixURL(forAppID: 220))

        let wine = URL(fileURLWithPath: "/w/wine64")
        _ = try await provisioner.provision(appID: 220, wineBinary: wine)
        _ = try await provisioner.provision(appID: 220, wineBinary: wine)
        #expect(fake.invocations.count == 1)   // second call short-circuits
    }

    @Test("Throws wineNotConfigured when no wine binary is set")
    func wineNotConfigured() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let provisioner = makeProvisioner(FakeProcessRunner(), tmp)
        await #expect(throws: PrefixProvisioner.ProvisionError.wineNotConfigured) {
            try await provisioner.provision(appID: 7, wineBinary: nil)
        }
    }

    @Test("Throws winebootFailed on a non-zero wineboot exit")
    func winebootFailed() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let fake = FakeProcessRunner()
        fake.queueResult(ProcessResult(exitCode: 1, standardError: Data("boom".utf8)))   // no reg created
        let provisioner = makeProvisioner(fake, tmp)
        await #expect(throws: PrefixProvisioner.ProvisionError.winebootFailed(exitCode: 1)) {
            try await provisioner.provision(appID: 7, wineBinary: URL(fileURLWithPath: "/w/wine64"))
        }
    }
}
