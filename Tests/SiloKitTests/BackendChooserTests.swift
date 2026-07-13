import Foundation
import Testing
@testable import SiloKit

@Suite("BackendChooser + PE imports")
struct BackendChooserTests {

    private func writePE(_ tmp: TempDir, _ name: String, magic: UInt16, machine: UInt16, imports: [String]) throws -> URL {
        try PEFixture.write(PEFixture.withImports(magic: magic, machine: machine, imports: imports), into: tmp, name)
    }

    // MARK: - PE import reader

    @Test("importedDLLs reads the import table for PE32+ and PE32, lowercased")
    func importsRead() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let x64 = try writePE(tmp, "a.exe", magic: 0x20b, machine: 0x8664, imports: ["d3d11.dll", "KERNEL32.dll"])
        #expect(WindowsExecutable.importedDLLs(of: x64) == ["d3d11.dll", "kernel32.dll"])
        let x86 = try writePE(tmp, "b.exe", magic: 0x10b, machine: 0x014c, imports: ["D3D9.dll"])
        #expect(WindowsExecutable.importedDLLs(of: x86) == ["d3d9.dll"])
    }

    @Test("importedDLLs fails open on a non-PE / malformed file (empty set)")
    func importsFailOpen() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let junk = tmp.url.appendingPathComponent("junk.bin")
        try Data([0x4D, 0x5A, 0x00, 0x01, 0x02, 0x03]).write(to: junk)     // "MZ" then garbage
        #expect(WindowsExecutable.importedDLLs(of: junk).isEmpty)
        #expect(WindowsExecutable.importedDLLs(of: tmp.url.appendingPathComponent("missing.exe")).isEmpty)
    }

    // MARK: - choose() (pure — bitness in, backend out)

    @Test("explicit choices are honored regardless of bitness — and win over a learned hint")
    func chooseExplicit() {
        #expect(BackendChooser.choose(.gptk, is32Bit: true) == .gptk)
        #expect(BackendChooser.choose(.dxmt, is32Bit: false) == .dxmt)
        // A user's pin always beats a reactively-learned hint (which only applies to `.auto`).
        #expect(BackendChooser.choose(.gptk, is32Bit: false, learned: .dxmt) == .gptk)
    }

    @Test("auto: 64-bit → GPTK, 32-bit → DXMT")
    func chooseAuto() {
        #expect(BackendChooser.choose(.auto, is32Bit: false) == .gptk)
        #expect(BackendChooser.choose(.auto, is32Bit: true) == .dxmt)   // GPTK is 64-bit-only
    }

    @Test("auto: a learned hint is consulted only for a 64-bit launch")
    func chooseLearnedConsulted64BitAutoOnly() {
        #expect(BackendChooser.choose(.auto, is32Bit: false, learned: .dxmt) == .dxmt)  // 64-bit auto uses the hint
        #expect(BackendChooser.choose(.auto, is32Bit: false, learned: nil) == .gptk)    // no hint → GPTK default
        #expect(BackendChooser.choose(.auto, is32Bit: false, learned: .gptk) == .gptk)  // defensive: hint agrees
        #expect(BackendChooser.choose(.auto, is32Bit: true, learned: .dxmt) == .dxmt)   // 32-bit: DXMT regardless
    }

    // MARK: - dxmtMightHelp()

    @Test("dxmtMightHelp: D3D10/11 → yes; D3D12 or D3D9-only → no; unknown → yes (permissive)")
    func mightHelp() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        func pe(_ n: String, _ imports: [String]) throws -> URL {
            try writePE(tmp, n, magic: 0x20b, machine: 0x8664, imports: imports)
        }
        #expect(BackendChooser.dxmtMightHelp(exe: try pe("d11.exe", ["d3d11.dll", "kernel32.dll"])))
        #expect(!BackendChooser.dxmtMightHelp(exe: try pe("d12.exe", ["d3d12.dll", "d3d11.dll"])))   // needs D3D12
        #expect(!BackendChooser.dxmtMightHelp(exe: try pe("d9.exe", ["d3d9.dll"])))                  // D3D9-only
        #expect(BackendChooser.dxmtMightHelp(exe: try pe("d9x.exe", ["d3d9.dll", "d3d10core.dll"]))) // has D3D10
        #expect(BackendChooser.dxmtMightHelp(exe: try pe("none.exe", ["kernel32.dll"])))             // dynamic → try
    }
}
