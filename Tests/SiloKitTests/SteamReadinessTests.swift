import Foundation
import Testing
@testable import SiloKit

@Suite("SteamReadiness")
struct SteamReadinessTests {

    /// A representative Wine `user.reg` snippet: Steam's ActiveProcess section with a live pid.
    private let withPid = """
    [Software\\Valve\\Steam\\ActiveProcess] 1700000000
    #time=1d000000
    "pid"=dword:0000007b
    "SteamClientDll"="C:\\Program Files (x86)\\Steam\\steamclient.dll"
    "Universe"="Public"
    """

    @Test("ready when ActiveProcess carries a non-zero pid")
    func ready() { #expect(SteamReadiness.hasActivePid(withPid)) }

    @Test("not ready when the pid is zero (Steam registered but not running)")
    func zeroPid() {
        #expect(!SteamReadiness.hasActivePid(
            withPid.replacingOccurrences(of: "dword:0000007b", with: "dword:00000000")))
    }

    @Test("not ready with no ActiveProcess section at all")
    func noSection() {
        #expect(!SteamReadiness.hasActivePid("[Software\\Valve\\Steam] 1\n\"x\"=\"y\"\n"))
    }

    @Test("a pid under a DIFFERENT section is not counted (section-scoped)")
    func wrongSection() {
        #expect(!SteamReadiness.hasActivePid("[Software\\Other\\App] 1\n\"pid\"=dword:0000007b\n"))
    }

    @Test("isReady reads the prefix's user.reg")
    func isReadyFromPrefix() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefix = try tmp.makeDir("bottle")
        #expect(!SteamReadiness.isReady(prefix: prefix))            // no user.reg yet → not ready
        try withPid.write(to: SteamReadiness.userReg(prefix: prefix), atomically: true, encoding: .utf8)
        #expect(SteamReadiness.isReady(prefix: prefix))             // pid present → ready
    }
}
