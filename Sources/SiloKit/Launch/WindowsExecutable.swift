import Foundation

/// Minimal PE (Portable Executable) header reader — just enough to tell a Windows `.exe`/`.dll`'s target
/// architecture from its COFF "Machine" field. Used to route by bitness: Apple's GPTK / D3DMetal is
/// 64-bit-only (Apple ships no 32-bit D3DMetal), so a 32-bit (i386) game can't run under GPTK and must use
/// DXMT. Pure + synchronous — reads only the two header words it needs.
enum WindowsExecutable {
    enum Machine: Sendable, Equatable {
        case i386      // 0x014c — 32-bit x86
        case amd64     // 0x8664 — 64-bit x86-64
        case arm64     // 0xAA64
        case other
    }

    /// The PE machine type of `url`, or nil if it can't be read as a PE — so callers can **fail open**
    /// (never block a launch on a file we couldn't parse).
    static func machine(of url: URL) -> Machine? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // DOS header: starts with "MZ"; the 4-byte little-endian at 0x3C (e_lfanew) is the PE header offset.
        guard let dos = try? handle.read(upToCount: 0x40), dos.count == 0x40,
              dos[dos.startIndex] == 0x4D, dos[dos.startIndex + 1] == 0x5A       // "MZ"
        else { return nil }
        let peOffset = dos.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0x3C, as: UInt32.self) }
        // PE header: "PE\0\0" signature (4 bytes) then the COFF Machine word (2 bytes, little-endian).
        guard (try? handle.seek(toOffset: UInt64(peOffset))) != nil,
              let head = try? handle.read(upToCount: 6), head.count == 6,
              head[head.startIndex] == 0x50, head[head.startIndex + 1] == 0x45,  // "PE"
              head[head.startIndex + 2] == 0, head[head.startIndex + 3] == 0     // "\0\0"
        else { return nil }
        let machine = UInt16(head[head.startIndex + 4]) | (UInt16(head[head.startIndex + 5]) << 8)
        switch machine {
        case 0x014c: return .i386
        case 0x8664: return .amd64
        case 0xAA64: return .arm64
        default: return .other
        }
    }

    /// True only for a **confirmed** 32-bit (i386) PE. Unreadable/unknown → false (fail open).
    static func is32Bit(_ url: URL) -> Bool { machine(of: url) == .i386 }

    /// The set of DLL names a PE statically imports, lowercased (e.g. `"d3d11.dll"`) — a hint at the graphics
    /// API a game needs. Walks BOTH the PE import directory (data directory 1) AND the delay-load import
    /// directory (index 13) — many titles delay-load `d3d12`/`d3d9`, so the delay table carries graphics-API
    /// names the regular table doesn't. **Fail-open**: any parse/bounds issue returns whatever was collected
    /// so far (empty on early failure) — never blocks a launch, and an EMPTY result means "unknown" (many
    /// games load Direct3D dynamically via `LoadLibrary`, so absence of a d3d import is NOT proof it doesn't
    /// use one). Memory-maps the file so a large `.exe` isn't read whole.
    static func importedDLLs(of url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        let n = data.count
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Set<String> in
            func u16(_ off: Int) -> UInt16? {
                guard off >= 0, off + 2 <= n else { return nil }
                return UInt16(raw[off]) | (UInt16(raw[off + 1]) << 8)
            }
            func u32(_ off: Int) -> UInt32? {
                guard off >= 0, off + 4 <= n else { return nil }
                return UInt32(raw[off]) | (UInt32(raw[off + 1]) << 8)
                    | (UInt32(raw[off + 2]) << 16) | (UInt32(raw[off + 3]) << 24)
            }
            // DOS "MZ" → e_lfanew → PE "PE\0\0".
            guard n >= 0x40, raw[0] == 0x4D, raw[1] == 0x5A, let peOff = u32(0x3C).map(Int.init),
                  peOff + 24 <= n, u16(peOff) == 0x4550, u16(peOff + 2) == 0 else { return [] }
            let numSections = Int(u16(peOff + 6) ?? 0)
            let sizeOptHdr = Int(u16(peOff + 20) ?? 0)
            let optHdr = peOff + 24
            guard let magic = u16(optHdr) else { return [] }
            // Data directories begin after the fixed optional-header body: 96 bytes (PE32) / 112 (PE32+).
            let dataDirs: Int
            switch magic {
            case 0x10b: dataDirs = optHdr + 96
            case 0x20b: dataDirs = optHdr + 112
            default: return []
            }
            // Section table (right after the optional header) → RVA→file-offset mapping.
            let sectionsStart = optHdr + sizeOptHdr
            struct Section { let va: UInt32; let vsize: UInt32; let rawSize: UInt32; let rawPtr: UInt32 }
            var sections: [Section] = []
            for i in 0..<min(numSections, 96) {
                let s = sectionsStart + i * 40
                guard let va = u32(s + 12), let vsize = u32(s + 8),
                      let rawSize = u32(s + 16), let rawPtr = u32(s + 20) else { break }
                sections.append(Section(va: va, vsize: vsize, rawSize: rawSize, rawPtr: rawPtr))
            }
            func fileOffset(_ rva: UInt32) -> Int? {
                for s in sections {
                    let span = max(s.vsize, s.rawSize)
                    if rva >= s.va, rva < s.va &+ span {
                        return Int(rva - s.va) + Int(s.rawPtr)
                    }
                }
                return nil
            }
            func cString(at off: Int, max: Int = 256) -> String? {
                guard off >= 0, off < n else { return nil }
                var bytes: [UInt8] = []
                var i = off
                while i < n, raw[i] != 0, bytes.count < max { bytes.append(raw[i]); i += 1 }
                return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
            }
            // NumberOfRvaAndSizes gates which data directories exist (index 13 only if > 13); ImageBase (PE32)
            // backs the legacy-VA delay-import fallback below.
            let numDirs = Int(u32(magic == 0x10b ? optHdr + 92 : optHdr + 108) ?? 0)
            let imageBaseLow = magic == 0x10b ? (u32(optHdr + 28) ?? 0) : 0

            var names: Set<String> = []
            // Import directory = data directory index 1: 20-byte IMAGE_IMPORT_DESCRIPTORs, name RVA at +12.
            if let importRVA = u32(dataDirs + 8), importRVA != 0, var desc = fileOffset(importRVA) {
                for _ in 0..<2048 {
                    guard let origFirstThunk = u32(desc), let nameRVA = u32(desc + 12),
                          let firstThunk = u32(desc + 16) else { break }
                    if origFirstThunk == 0, nameRVA == 0, firstThunk == 0 { break }   // terminator
                    if nameRVA != 0, let off = fileOffset(nameRVA), let name = cString(at: off) {
                        names.insert(name.lowercased())
                    }
                    desc += 20
                }
            }
            // Delay-load import directory = data directory index 13: 32-byte ImgDelayDescr, name at +4. Modern
            // linkers store an RVA (grAttrs bit 0 = 1); the legacy format stores a VA → subtract ImageBase.
            if numDirs > 13, let delayRVA = u32(dataDirs + 13 * 8), delayRVA != 0, var desc = fileOffset(delayRVA) {
                for _ in 0..<2048 {
                    guard let attrs = u32(desc), let nameField = u32(desc + 4), let hmod = u32(desc + 8) else { break }
                    if attrs == 0, nameField == 0, hmod == 0 { break }   // all-zero terminator
                    let nameRVA = (attrs & 1) == 1 ? nameField : nameField &- imageBaseLow
                    if nameRVA != 0, let off = fileOffset(nameRVA), let name = cString(at: off) {
                        names.insert(name.lowercased())
                    }
                    desc += 32
                }
            }
            return names
        }
    }
}
