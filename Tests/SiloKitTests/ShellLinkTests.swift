import Foundation
import Testing
@testable import SiloKit

@Suite("ShellLink (.lnk) parser")
struct ShellLinkTests {
    /// The real Start-Menu shortcut GravityMark's MSI installer created (committed as a fixture). This is the
    /// exact case that motivated the feature: the bare exe is `Browser.exe`, which is useless without the
    /// args + working dir the shortcut carries.
    private func gravityMark() throws -> ShellLink {
        let data = try Data(contentsOf: FixtureLoader.url("GravityMark.lnk"))
        return try #require(ShellLink.parse(data))
    }

    @Test("Parses target, name, working dir, arguments, and icon from a real installer shortcut")
    func parsesRealShortcut() throws {
        let link = try gravityMark()
        #expect(link.targetPath == #"C:\Program Files\GravityMark\bin\Browser.exe"#)
        #expect(link.name == "GravityMark GPU Benchmark")
        #expect(link.workingDirectory == #"C:\Program Files\GravityMark\bin\"#)
        #expect(link.arguments == "-root browser/ ../browser.zip")
        #expect(link.iconLocation?.hasSuffix(#"main.ico"#) == true)
    }

    @Test("Trailing NULs are trimmed from counted strings")
    func trimsTrailingNul() throws {
        let link = try gravityMark()
        // Writers often fold the NUL terminator into the character count; it must not leak into the value.
        #expect(link.name?.contains("\0") == false)
        #expect(link.arguments?.contains("\0") == false)
    }

    @Test("Malformed or non-.lnk input returns nil, never crashes")
    func rejectsGarbage() throws {
        #expect(ShellLink.parse(Data()) == nil)                       // empty
        #expect(ShellLink.parse(Data([0x4C, 0x00, 0x00, 0x00])) == nil) // right size word, too short
        #expect(ShellLink.parse(Data(repeating: 0, count: 200)) == nil) // header size 0 ≠ 0x4C
        // Correct header size but wrong CLSID.
        var wrongClsid = [UInt8](repeating: 0, count: 200)
        wrongClsid[0] = 0x4C
        #expect(ShellLink.parse(Data(wrongClsid)) == nil)
        // Truncating the real file mid-structure must fail closed, not trap.
        let full = try Data(contentsOf: FixtureLoader.url("GravityMark.lnk"))
        for cut in [0x50, 0x100, 0x200, full.count - 4] {
            _ = ShellLink.parse(full.prefix(cut))                    // just must not crash
        }
    }
}
