import Foundation

/// Extracts an application icon from a Windows PE executable (`.exe`) as `.ico` data that `NSImage` can
/// decode. Clean-room implementation of the public PE / resource-directory / `.ico` formats — no third-party
/// code. Used to give user-added non-Steam games a real icon in the library grid (Steam games use cover-art).
///
/// Pure + Foundation-only (returns `.ico` `Data`, not an `NSImage`), so it unit-tests headlessly. Every read
/// is bounds-checked: a truncated or hostile file yields `nil`, never a crash.
public enum PEIcon {

    // Resource type IDs (PE `.rsrc`): RT_ICON = 3, RT_GROUP_ICON = 14.
    private static let rtIcon: UInt32 = 3
    private static let rtGroupIcon: UInt32 = 14

    /// The largest icon embedded in `executable` (PE bytes), as a single-image `.ico`, or `nil` if the file
    /// isn't a PE or carries no icon.
    public static func icoData(fromExecutable data: Data) -> Data? {
        let b = [UInt8](data)
        guard let rsrc = resourceSection(b) else { return nil }

        // RT_GROUP_ICON → the directory listing each icon's dimensions + the RT_ICON id holding its image.
        guard let group = leaf(b, rsrc, type: rtGroupIcon),
              let best = largestGroupEntry(b, at: group.offset, size: group.size) else { return nil }
        // RT_ICON with that id → the raw image (a DIB or PNG).
        guard let image = leaf(b, rsrc, type: rtIcon, id: UInt32(best.iconID)) else { return nil }

        return assembleICO(entry12: best.entry12, imageBytes: b[image.offset..<image.offset + image.size])
    }

    // MARK: - PE section table → the .rsrc section

    /// `base` = the `.rsrc` file offset (= the resource directory root); `virtualAddress` = its RVA, used to
    /// convert a data-entry RVA back into a file offset.
    private struct Section { let base: Int; let virtualAddress: Int }

    private static func resourceSection(_ b: [UInt8]) -> Section? {
        guard b.count > 0x40, b[0] == 0x4D, b[1] == 0x5A else { return nil }   // 'MZ'
        guard let peOff = u32(b, 0x3C).map(Int.init), peOff + 24 <= b.count,
              u32(b, peOff) == 0x0000_4550 else { return nil }                 // 'PE\0\0'
        let coff = peOff + 4
        guard let sectionCount = u16(b, coff + 2).map(Int.init),
              let optSize = u16(b, coff + 16).map(Int.init) else { return nil }
        let table = coff + 20 + optSize
        for i in 0..<sectionCount {
            let s = table + i * 40
            guard s + 40 <= b.count else { return nil }
            let name = String(bytes: b[s..<s + 8].prefix { $0 != 0 }, encoding: .ascii)
            if name == ".rsrc", let va = u32(b, s + 12).map(Int.init), let raw = u32(b, s + 20).map(Int.init),
               raw > 0, raw <= b.count {
                return Section(base: raw, virtualAddress: va)
            }
        }
        return nil
    }

    // MARK: - Resource directory navigation
    //
    // The .rsrc tree is 3 levels (Type → Name/ID → Language). Each directory: a 16-byte header then entries of
    // (id-or-name U32, offset U32). An offset with the high bit set points to a sub-directory; cleared, to a
    // 16-byte DATA_ENTRY whose first U32 is the data RVA and second its size. Directory offsets are relative
    // to the section base.

    private struct Leaf { let offset: Int; let size: Int }

    /// Walk Type=`type` → Name/ID matching `id` (or the first, if nil) → first Language → the data entry,
    /// returning the image bytes' file offset + size.
    private static func leaf(_ b: [UInt8], _ s: Section, type: UInt32, id: UInt32? = nil) -> Leaf? {
        guard let typeDir = subdirectory(b, base: s.base, dirOffset: 0, matchingID: type),
              let nameDir = subdirectory(b, base: s.base, dirOffset: typeDir, matchingID: id),
              let langDir = subdirectory(b, base: s.base, dirOffset: nameDir, matchingID: nil),
              let dataEntry = firstEntry(b, base: s.base, dirOffset: langDir), !dataEntry.isDirectory
        else { return nil }
        // dataEntry points to a DATA_ENTRY: first U32 is the data RVA, second its size.
        let de = s.base + dataEntry.offset
        guard de + 8 <= b.count, let rva = u32(b, de).map(Int.init), let size = u32(b, de + 4).map(Int.init)
        else { return nil }
        let fileOffset = s.base + (rva - s.virtualAddress)   // RVA → file offset within .rsrc
        guard size > 0, fileOffset >= 0, fileOffset + size <= b.count else { return nil }
        return Leaf(offset: fileOffset, size: size)
    }

    private struct Entry { let isDirectory: Bool; let offset: Int }

    /// Offset (from base) of the sub-directory under `dirOffset` whose ID == `id`; if `id` is nil, the first
    /// entry's sub-directory.
    private static func subdirectory(_ b: [UInt8], base: Int, dirOffset: Int, matchingID id: UInt32?) -> Int? {
        let dir = base + dirOffset
        guard dir + 16 <= b.count,
              let named = u16(b, dir + 12).map(Int.init), let ided = u16(b, dir + 14).map(Int.init) else { return nil }
        let entries = dir + 16
        for i in 0..<(named + ided) {
            let e = entries + i * 8
            guard e + 8 <= b.count, let nameOrID = u32(b, e), let off = u32(b, e + 4) else { return nil }
            let isNamed = (nameOrID & 0x8000_0000) != 0    // name entries — we only match numeric IDs
            let isDir = (off & 0x8000_0000) != 0
            if let id {
                if !isNamed, nameOrID == id, isDir { return Int(off & 0x7FFF_FFFF) }
            } else if isDir {
                return Int(off & 0x7FFF_FFFF)              // first sub-directory
            }
        }
        return nil
    }

    /// The first entry under `dirOffset` as a (isDirectory, offset-from-base) pair.
    private static func firstEntry(_ b: [UInt8], base: Int, dirOffset: Int) -> Entry? {
        let dir = base + dirOffset
        guard dir + 16 <= b.count,
              let named = u16(b, dir + 12).map(Int.init), let ided = u16(b, dir + 14).map(Int.init),
              named + ided > 0, let off = u32(b, dir + 16 + 4) else { return nil }
        return Entry(isDirectory: (off & 0x8000_0000) != 0, offset: Int(off & 0x7FFF_FFFF))
    }

    // MARK: - GRPICONDIR (the icon directory) → pick the largest entry

    /// First 12 bytes of an ICONDIRENTRY (width…bytesInRes), plus the RT_ICON id that holds the image.
    private struct GroupEntry { let entry12: [UInt8]; let iconID: UInt16 }

    /// Parse the GRPICONDIR at `offset` and return the entry with the most image bytes (the highest-res icon).
    private static func largestGroupEntry(_ b: [UInt8], at offset: Int, size: Int) -> GroupEntry? {
        // Header: reserved(2), type(2), count(2). Then count × GRPICONDIRENTRY (14 bytes).
        guard size >= 6, let count = u16(b, offset + 4).map(Int.init), count > 0 else { return nil }
        var best: GroupEntry?
        var bestBytes: UInt32 = 0
        for i in 0..<count {
            let e = offset + 6 + i * 14
            guard e + 14 <= offset + size, e + 14 <= b.count,
                  let bytesInRes = u32(b, e + 8), let iconID = u16(b, e + 12) else { continue }
            if best == nil || bytesInRes > bestBytes {
                bestBytes = bytesInRes
                // ICONDIRENTRY shares its first 12 bytes (width…bytesInRes) with GRPICONDIRENTRY.
                best = GroupEntry(entry12: Array(b[e..<e + 12]), iconID: iconID)
            }
        }
        return best
    }

    // MARK: - .ico assembly

    /// Build a single-image `.ico`: ICONDIR (6) + one ICONDIRENTRY (16) + the icon image bytes.
    private static func assembleICO(entry12: [UInt8], imageBytes: ArraySlice<UInt8>) -> Data {
        var ico: [UInt8] = [0, 0, 1, 0, 1, 0]           // reserved=0, type=1 (icon), count=1
        ico += entry12                                  // width…bytesInRes (12 bytes, copied verbatim)
        ico += le32(6 + 16)                             // image follows the single 16-byte directory entry
        ico += imageBytes
        return Data(ico)
    }

    // MARK: - Little-endian readers (bounds-checked)

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16? {
        guard i >= 0, i + 2 <= b.count else { return nil }
        return UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32? {
        guard i >= 0, i + 4 <= b.count else { return nil }
        return UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }
    private static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
}
