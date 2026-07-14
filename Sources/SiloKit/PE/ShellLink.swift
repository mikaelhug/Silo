import Foundation

/// Parsed contents of a Windows Shell Link (`.lnk`) — the launch metadata an installer bakes into the
/// Start-Menu shortcut it creates: the target executable, its arguments, and its "start in" working
/// directory. Silo reads these after running an installer so a manual game inherits the *correct* launch
/// (target + args + cwd) instead of the user hand-picking a bare `.exe` (see `BottleShortcuts`).
///
/// Clean-room implementation of the public MS-SHLLINK format — no third-party code, Foundation-only, so it
/// unit-tests headlessly. Every read is bounds-checked: a truncated or hostile file yields `nil`, never a
/// crash (mirrors `PEIcon`). All strings are returned as the raw Windows values (e.g. `C:\Program Files\…`);
/// mapping a Windows path to a bottle's unix path is the caller's job, not the parser's.
public struct ShellLink: Equatable, Sendable {
    /// Absolute Windows target path from the LinkInfo block (`LocalBasePath` [+ `CommonPathSuffix`]).
    public var targetPath: String?
    /// Human-friendly description (`NAME_STRING`) — the label the installer gave the shortcut.
    public var name: String?
    /// The "start in" directory (`WORKING_DIR`) — the cwd the target expects.
    public var workingDirectory: String?
    /// Command-line arguments (`COMMAND_LINE_ARGUMENTS`) passed to the target.
    public var arguments: String?
    /// Icon source (`ICON_LOCATION`) — a path (possibly to a `.ico`/`.exe`) with an index elsewhere.
    public var iconLocation: String?

    // MARK: - Parse

    private static let headerSize: UInt32 = 0x0000_004C
    // The Shell Link CLSID {00021401-0000-0000-C000-000000000046}, in on-disk byte order.
    private static let clsid: [UInt8] = [
        0x01, 0x14, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46,
    ]

    // LinkFlags bits we care about.
    private static let hasTargetIDList = 0
    private static let hasLinkInfo = 1
    private static let hasName = 2
    private static let hasRelativePath = 3
    private static let hasWorkingDir = 4
    private static let hasArguments = 5
    private static let hasIconLocation = 6
    private static let isUnicode = 7

    /// Parse `.lnk` bytes. Returns `nil` if `data` isn't a Shell Link (bad header size or CLSID) or is
    /// truncated past a field boundary.
    public static func parse(_ data: Data) -> ShellLink? {
        let b = [UInt8](data)
        guard b.count >= 0x4C, u32(b, 0) == headerSize else { return nil }
        guard Array(b[4..<20]) == clsid else { return nil }
        guard let flags = u32(b, 20) else { return nil }
        func flag(_ bit: Int) -> Bool { flags & (1 << bit) != 0 }
        let unicode = flag(isUnicode)

        var off = 0x4C

        // LinkTargetIDList: a `u16` size prefix then that many bytes. We source the target from LinkInfo
        // instead (a resolved absolute path), so this list is only skipped.
        if flag(hasTargetIDList) {
            guard let size = u16(b, off) else { return nil }
            off += 2 + Int(size)
        }

        var link = ShellLink()

        // LinkInfo: self-sized; carries the target's absolute local path.
        if flag(hasLinkInfo) {
            guard let size = u32(b, off).map(Int.init), size >= 0, off + size <= b.count else { return nil }
            link.targetPath = localBasePath(b, at: off)
            off += size
        }

        // StringData: each present-if-flag, in this fixed order; a `u16` character count then the chars
        // (2 bytes each when Unicode). Not null-terminated by spec, though writers often include the NUL in
        // the count — trailing NULs are trimmed.
        func readString(_ present: Bool) -> String? {
            guard present else { return nil }
            guard let s = countedString(b, at: &off, unicode: unicode) else { return nil }
            return s
        }
        // Order matters: NAME, RELATIVE_PATH, WORKING_DIR, ARGUMENTS, ICON_LOCATION.
        link.name = readString(flag(hasName))
        _ = readString(flag(hasRelativePath))                 // parsed to advance the cursor; unused
        link.workingDirectory = readString(flag(hasWorkingDir))
        link.arguments = readString(flag(hasArguments))
        link.iconLocation = readString(flag(hasIconLocation))
        return link
    }

    // MARK: - LinkInfo

    /// Extract the target's absolute local path from a LinkInfo block starting at `base`. Prefers the
    /// Unicode `LocalBasePath` when present (header ≥ 0x24), else the ANSI one; appends `CommonPathSuffix`.
    private static func localBasePath(_ b: [UInt8], at base: Int) -> String? {
        guard let headerLen = u32(b, base + 4).map(Int.init),
              let liFlags = u32(b, base + 8),
              liFlags & 0x1 != 0 else { return nil }            // VolumeIDAndLocalBasePath present
        guard let baseOff = u32(b, base + 16).map(Int.init) else { return nil }

        var path: String?
        if headerLen >= 0x24, let uniOff = u32(b, base + 28).map(Int.init), uniOff != 0 {
            path = utf16Z(b, base + uniOff)
        }
        if path == nil { path = ansiZ(b, base + baseOff) }
        guard var result = path else { return nil }

        // CommonPathSuffix (ANSI at offset 24, or Unicode at offset 32 when header ≥ 0x24). Usually empty.
        if headerLen >= 0x24, let uniSuffix = u32(b, base + 32).map(Int.init), uniSuffix != 0,
           let suffix = utf16Z(b, base + uniSuffix) {
            result += suffix
        } else if let sOff = u32(b, base + 24).map(Int.init), sOff != 0,
                  let suffix = ansiZ(b, base + sOff), !suffix.isEmpty {
            result += suffix
        }
        return result
    }

    // MARK: - Byte readers (all bounds-checked → nil, never trap)

    private static func u16(_ b: [UInt8], _ o: Int) -> UInt16? {
        guard o >= 0, o + 2 <= b.count else { return nil }
        return UInt16(b[o]) | UInt16(b[o + 1]) << 8
    }

    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32? {
        guard o >= 0, o + 4 <= b.count else { return nil }
        return UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    /// A `u16`-counted string at `*off`, advancing `off` past it. Unicode → UTF-16LE (count is characters,
    /// 2 bytes each); else ANSI (Windows-1252). Trailing NULs trimmed. Returns `nil` if it runs past the end.
    private static func countedString(_ b: [UInt8], at off: inout Int, unicode: Bool) -> String? {
        guard let count = u16(b, off).map(Int.init) else { return nil }
        off += 2
        let bytes = unicode ? count * 2 : count
        guard off + bytes <= b.count else { return nil }
        let slice = Array(b[off..<off + bytes])
        off += bytes
        let s: String
        if unicode {
            var units: [UInt16] = []
            units.reserveCapacity(count)
            var i = 0
            while i + 1 < slice.count {
                units.append(UInt16(slice[i]) | UInt16(slice[i + 1]) << 8)
                i += 2
            }
            s = String(decoding: units, as: UTF16.self)
        } else {
            s = windows1252(slice)
        }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    /// NUL-terminated ANSI (Windows-1252) string at `o`.
    private static func ansiZ(_ b: [UInt8], _ o: Int) -> String? {
        guard o >= 0, o < b.count else { return nil }
        var end = o
        while end < b.count, b[end] != 0 { end += 1 }
        return windows1252(Array(b[o..<end]))
    }

    /// NUL-terminated UTF-16LE string at `o`.
    private static func utf16Z(_ b: [UInt8], _ o: Int) -> String? {
        guard o >= 0, o < b.count else { return nil }
        var units: [UInt16] = []
        var i = o
        while i + 2 <= b.count {
            let u = UInt16(b[i]) | UInt16(b[i + 1]) << 8
            if u == 0 { break }
            units.append(u)
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Decode Windows-1252/Latin-1 bytes. Shortcut paths are ASCII in practice; this keeps non-ASCII bytes
    /// lossless as their Latin-1 code points rather than dropping them.
    private static func windows1252(_ bytes: [UInt8]) -> String {
        String(bytes.map { Character(UnicodeScalar($0)) })
    }
}
