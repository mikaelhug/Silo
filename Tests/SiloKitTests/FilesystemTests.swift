import Foundation
import Testing
@testable import SiloKit

@Suite("Filesystem")
struct FilesystemTests {

    /// Exercises the REAL `statfs` path (the unit tests elsewhere stub the FAT check); a temp dir lives on
    /// the test machine's boot volume (APFS), which is not FAT and must yield a readable type string.
    @Test("type(of:) reads a real volume's fs type; isFATFamily is false on the test volume")
    func realStatfs() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let type = try #require(Filesystem.type(of: tmp.url))
        #expect(!type.isEmpty)
        #expect(type == type.lowercased())          // normalized to lowercase
        #expect(!Filesystem.isFATFamily(tmp.url))    // a dev machine's volume isn't exFAT/FAT
    }

    @Test("type(of:) returns nil for a path that doesn't exist")
    func missingPath() {
        #expect(Filesystem.type(of: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/x")) == nil)
    }
}
