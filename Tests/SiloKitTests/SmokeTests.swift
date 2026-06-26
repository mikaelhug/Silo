import Testing
@testable import SiloKit

@Suite("Smoke")
struct SmokeTests {
    @Test("Version metadata is present")
    func versionMetadata() {
        #expect(!Silo.version.isEmpty)
        #expect(Silo.bundleID == "com.mikael.silo")
        #expect(Silo.appName == "Silo")
    }
}
