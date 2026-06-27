import Foundation
import Testing
@testable import SiloKit

@MainActor
@Suite("SteamLoginViewModel")
struct SteamLoginViewModelTests {

    private func make() -> SteamLoginViewModel {
        SteamLoginViewModel(steamCMD: SteamCMDClient(
            runner: FakeProcessRunner(), session: FakeURLProtocol.makeSession(),
            paths: AppPaths(supportDir: URL(fileURLWithPath: "/tmp/silo-x"))))
    }

    @Test("Recognises a successful SteamCMD login and reports the username back")
    func success() {
        let vm = make()
        var loggedInUser: String?
        vm.onLoggedIn = { loggedInUser = $0 }
        vm.classify("Logging in user 'alice'...\nWaiting for user info...OK", user: "alice")
        #expect(vm.loggedIn)
        #expect(loggedInUser == "alice")
        #expect(!vm.needsGuardCode)
    }

    @Test("Detects a Steam Guard prompt")
    func guardPrompt() {
        let vm = make()
        vm.classify("This account is protected by Steam Guard. Please enter the code...", user: "alice")
        #expect(!vm.loggedIn)
        #expect(vm.needsGuardCode)
    }

    @Test("Reports invalid-password failure")
    func failure() {
        let vm = make()
        vm.classify("FAILED login with result code Invalid Password", user: "alice")
        #expect(!vm.loggedIn)
        #expect(vm.statusMessage?.contains("failed") == true)
    }

    @Test("Pre-seeded username starts logged in (cached SteamCMD token)")
    func cached() {
        let vm = SteamLoginViewModel(steamCMD: SteamCMDClient(
            runner: FakeProcessRunner(), session: FakeURLProtocol.makeSession(),
            paths: AppPaths(supportDir: URL(fileURLWithPath: "/tmp/silo-x"))), username: "bob")
        #expect(vm.loggedIn)
        #expect(vm.username == "bob")
    }
}
