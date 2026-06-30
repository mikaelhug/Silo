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
}
