import Foundation
import Testing
@testable import SiloKit

@Suite("BackendChooser + PE imports")
struct BackendChooserTests {

    /// Build a minimal-but-valid-enough PE for `WindowsExecutable` to parse: DOS + PE headers, one `.idata`
    /// section whose VirtualAddress == PointerToRawData (so RVA == file offset), and an import directory of
    /// the given DLL names. `magic` = 0x20b (PE32+/64-bit) or 0x10b (PE32/32-bit).
    private func makePE(magic: UInt16, machine: UInt16, imports: [String]) -> Data {
        var b = [UInt8](repeating: 0, count: 0x400)
        func setU16(_ off: Int, _ v: UInt16) { b[off] = UInt8(v & 0xFF); b[off + 1] = UInt8(v >> 8) }
        func setU32(_ off: Int, _ v: UInt32) {
            b[off] = UInt8(v & 0xFF); b[off + 1] = UInt8((v >> 8) & 0xFF)
            b[off + 2] = UInt8((v >> 16) & 0xFF); b[off + 3] = UInt8((v >> 24) & 0xFF)
        }
        func setStr(_ off: Int, _ s: String) { for (i, c) in Array(s.utf8).enumerated() { b[off + i] = c } }
        b[0] = 0x4D; b[1] = 0x5A                                     // "MZ"
        let pe = 0x40
        setU32(0x3C, UInt32(pe))                                    // e_lfanew
        b[pe] = 0x50; b[pe + 1] = 0x45                              // "PE\0\0"
        setU16(pe + 4, machine)                                     // COFF Machine
        setU16(pe + 6, 1)                                           // NumberOfSections
        let dataDirBase = magic == 0x20b ? 112 : 96
        let sizeOpt = dataDirBase + 16                              // opt-header body + export + import data dirs
        setU16(pe + 20, UInt16(sizeOpt))                            // SizeOfOptionalHeader
        setU16(pe + 24, magic)                                      // Magic
        let dataDirs = pe + 24 + dataDirBase
        let importOff = 0x200
        setU32(dataDirs + 8, UInt32(importOff))                     // import dir RVA (index 1)
        setU32(dataDirs + 12, UInt32(20 * (imports.count + 1)))     // import dir size
        let sec = pe + 24 + sizeOpt
        setStr(sec, ".idata")
        setU32(sec + 8, 0x200)                                      // VirtualSize (covers descriptors + names)
        setU32(sec + 12, UInt32(importOff))                         // VirtualAddress == PointerToRawData
        setU32(sec + 16, 0x200)                                     // SizeOfRawData
        setU32(sec + 20, UInt32(importOff))                         // PointerToRawData
        var nameOff = 0x300
        for (i, dll) in imports.enumerated() {
            let d = importOff + i * 20
            setU32(d, 1)                                            // OriginalFirstThunk (nonzero)
            setU32(d + 12, UInt32(nameOff))                         // Name RVA
            setU32(d + 16, 1)                                       // FirstThunk (nonzero)
            setStr(nameOff, dll)                                    // null-terminated (buffer is zero-filled)
            nameOff += dll.utf8.count + 1
        }
        return Data(b)                                             // trailing all-zero import descriptor terminates
    }

    private func writePE(_ tmp: TempDir, _ name: String, magic: UInt16, machine: UInt16, imports: [String]) throws -> URL {
        let url = tmp.url.appendingPathComponent(name)
        try makePE(magic: magic, machine: machine, imports: imports).write(to: url)
        return url
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

    // MARK: - choose()

    @Test("explicit choices are honored regardless of the binary")
    func chooseExplicit() {
        #expect(BackendChooser.choose(.gptk, exe: nil) == .gptk)
        #expect(BackendChooser.choose(.dxmt, exe: nil) == .dxmt)
    }

    @Test("auto: 64-bit → GPTK, 32-bit → DXMT, unknown → GPTK")
    func chooseAuto() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let x64 = try writePE(tmp, "g64.exe", magic: 0x20b, machine: 0x8664, imports: ["d3d11.dll"])
        let x86 = try writePE(tmp, "g32.exe", magic: 0x10b, machine: 0x014c, imports: ["d3d9.dll"])
        #expect(BackendChooser.choose(.auto, exe: x64) == .gptk)
        #expect(BackendChooser.choose(.auto, exe: x86) == .dxmt)   // GPTK is 64-bit-only
        #expect(BackendChooser.choose(.auto, exe: nil) == .gptk)   // unresolved binary → proven default
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
