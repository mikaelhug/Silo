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
}
