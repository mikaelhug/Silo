import Foundation

/// Synthesises minimal Portable Executable byte blobs for the header/import parsers under test — the single
/// home for hand-rolled PE bytes (previously copied across four test files). `header` is enough for
/// `WindowsExecutable.machine`/`is32Bit`; `withImports` adds a `.idata` section for
/// `WindowsExecutable.importedDLLs` / `BackendChooser`.
enum PEFixture {

    /// A minimal-but-valid PE: "MZ" DOS header, `e_lfanew` → PE header, "PE\0\0" + the COFF Machine word
    /// (0x014c = i386, 0x8664 = amd64, 0xAA64 = arm64).
    static func header(machine: UInt16, peOffset: Int = 0x40) -> Data {
        var d = Data(count: peOffset + 6)
        d[0] = 0x4D; d[1] = 0x5A                                        // "MZ"
        d[0x3C] = UInt8(peOffset & 0xFF)                               // e_lfanew (LE uint32)
        d[0x3D] = UInt8((peOffset >> 8) & 0xFF)
        d[0x3E] = UInt8((peOffset >> 16) & 0xFF)
        d[0x3F] = UInt8((peOffset >> 24) & 0xFF)
        d[peOffset] = 0x50; d[peOffset + 1] = 0x45                     // "PE"
        d[peOffset + 2] = 0; d[peOffset + 3] = 0                       // "\0\0"
        d[peOffset + 4] = UInt8(machine & 0xFF)                        // Machine (LE uint16)
        d[peOffset + 5] = UInt8((machine >> 8) & 0xFF)
        return d
    }

    /// A PE with one `.idata` section whose VirtualAddress == PointerToRawData (so RVA == file offset) and an
    /// import directory of the given DLL names. `magic` = 0x20b (PE32+/64-bit) or 0x10b (PE32/32-bit).
    static func withImports(magic: UInt16, machine: UInt16, imports: [String]) -> Data {
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

    /// Write `data` to a file under `tmp` and return its URL.
    static func write(_ data: Data, into tmp: TempDir, _ name: String) throws -> URL {
        let url = tmp.url.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}
