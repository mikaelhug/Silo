import Foundation
import Testing
@testable import SiloKit

@Suite("Silo.wineEnvironment")
struct SiloEnvironmentTests {

    @Test("Base wine env: isolated WINEPREFIX, build-gated logging, bundled DYLD fallback")
    func base() {
        let env = Silo.wineEnvironment(
            prefix: URL(fileURLWithPath: "/p/220"),
            wine: URL(fileURLWithPath: "/rt/bin/wine"))
        #expect(env["WINEPREFIX"] == "/p/220")
        #expect(env["WINEDEBUG"] == Silo.wineDebug)   // verbose in local builds, "-all" under CI
        // <wine root>/lib/silo-bundled is first (so wine's dlopen'd deps resolve from the hermetic bundle);
        // /usr/local/lib (Homebrew) is deliberately NOT on the path — it leaked a duplicate gtk into wine.
        #expect(env["DYLD_FALLBACK_LIBRARY_PATH"] == "/rt/lib/silo-bundled:/usr/lib")
        #expect(env.count == 3)   // base only — callers layer their own overrides
    }

    @Test("enforceMsync sets WINEMSYNC and strips a user's WINEESYNC (the co-residency rule)")
    func enforceMsync() {
        var env = ["WINEESYNC": "1", "FOO": "bar"]
        Silo.enforceMsync(&env)
        #expect(env["WINEMSYNC"] == "1")
        #expect(env["WINEESYNC"] == nil)   // a split sync mode would fork a second wineserver
        #expect(env["FOO"] == "bar")       // everything else untouched
    }

    @Test("msyncWineEnvironment = the base wine env + the co-residency sync rule")
    func msyncEnvironment() {
        let wine = URL(fileURLWithPath: "/rt/bin/wine64")
        let env = Silo.msyncWineEnvironment(prefix: URL(fileURLWithPath: "/bottle"), wine: wine)
        #expect(env["WINEPREFIX"] == "/bottle")
        #expect(env["WINEMSYNC"] == "1")
        #expect(env["WINEESYNC"] == nil)
        #expect(env["DYLD_FALLBACK_LIBRARY_PATH"] == wine.siloDyldFallback)
    }
}
