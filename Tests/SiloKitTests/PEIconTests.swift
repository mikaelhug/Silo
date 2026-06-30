import Foundation
import Testing
@testable import SiloKit

@Suite("PEIcon")
struct PEIconTests {

    @Test("rejects non-PE / truncated data without crashing")
    func rejectsGarbage() {
        #expect(PEIcon.icoData(fromExecutable: Data()) == nil)
        #expect(PEIcon.icoData(fromExecutable: Data("not an executable at all".utf8)) == nil)
        // 'MZ' but no valid PE header behind it.
        #expect(PEIcon.icoData(fromExecutable: Data([0x4D, 0x5A] + [UInt8](repeating: 0, count: 300))) == nil)
    }

    @Test("extracts an icon from a PE into a valid single-image .ico")
    func extractsIcon() throws {
        let image = [UInt8](repeating: 0xAB, count: 40)
        let exe = SyntheticPE.build([.init(id: 1, image: image, width: 32, height: 32, bitCount: 32)])
        let ico = try #require(PEIcon.icoData(fromExecutable: exe))
        #expect([UInt8](ico.prefix(6)) == [0, 0, 1, 0, 1, 0])   // ICONDIR: reserved=0, type=1, count=1
        #expect(ico[6] == 32)                                   // ICONDIRENTRY width
        #expect(ico[7] == 32)                                   // height
        #expect(ico.count == 6 + 16 + 40)                       // dir + entry + image
        #expect([UInt8](ico.suffix(40)) == image)
    }

    @Test("picks the icon with the most image bytes when several are present")
    func picksLargest() throws {
        let exe = SyntheticPE.build([
            .init(id: 1, image: [UInt8](repeating: 0xAA, count: 10), width: 16, height: 16, bitCount: 32),
            .init(id: 2, image: [UInt8](repeating: 0xCC, count: 50), width: 48, height: 48, bitCount: 32),
        ])
        let ico = try #require(PEIcon.icoData(fromExecutable: exe))
        #expect(ico.count == 6 + 16 + 50)                       // the 50-byte icon, not the 10-byte one
        #expect([UInt8](ico.suffix(50)) == [UInt8](repeating: 0xCC, count: 50))
    }
}

/// Builds a minimal-but-valid PE byte buffer carrying one or more icons (a `.rsrc` section with the full
/// Type→Name→Language resource tree for RT_GROUP_ICON + RT_ICON), for testing `PEIcon` headlessly.
private enum SyntheticPE {
    struct Icon { let id: UInt16; let image: [UInt8]; let width: UInt8; let height: UInt8; let bitCount: UInt16 }

    static func build(_ icons: [Icon]) -> Data {
        let n = icons.count
        let sectionBase = 0x80, va = 0x1000
        let lang: UInt32 = 1033, groupID: UInt32 = 1

        // Pass 1: allocate section-relative offsets in layout order.
        var cur = 0
        func alloc(_ size: Int) -> Int { defer { cur += size }; return cur }
        let rootDir = alloc(16 + 2 * 8)
        let type3Dir = alloc(16 + n * 8)
        let type14Dir = alloc(16 + 8)
        let iconNameDir = (0..<n).map { _ in alloc(16 + 8) }
        let groupNameDir = alloc(16 + 8)
        let iconLangDir = (0..<n).map { _ in alloc(16 + 8) }
        let groupLangDir = alloc(16 + 8)
        let iconData = (0..<n).map { _ in alloc(16) }
        let groupData = alloc(16)
        let grpiconDir = alloc(6 + n * 14)
        let iconImage = icons.map { alloc($0.image.count) }
        let sectionSize = cur

        // Pass 2: fill the section.
        var sec = [UInt8](repeating: 0, count: sectionSize)
        func u16(_ o: Int, _ v: UInt16) { sec[o] = UInt8(v & 0xFF); sec[o + 1] = UInt8(v >> 8) }
        func u32(_ o: Int, _ v: UInt32) {
            sec[o] = UInt8(v & 0xFF); sec[o + 1] = UInt8((v >> 8) & 0xFF)
            sec[o + 2] = UInt8((v >> 16) & 0xFF); sec[o + 3] = UInt8((v >> 24) & 0xFF)
        }
        func dir(_ off: Int, idEntries: Int) { u16(off + 14, UInt16(idEntries)) }   // named=0, id count @ +14
        func entry(_ off: Int, id: UInt32, child: Int, isDir: Bool) {
            u32(off, id); u32(off + 4, UInt32(child) | (isDir ? 0x8000_0000 : 0))
        }
        func data(_ off: Int, at dataOffset: Int, size: Int) {
            u32(off, UInt32(va + dataOffset)); u32(off + 4, UInt32(size))   // RVA + size
        }

        dir(rootDir, idEntries: 2)
        entry(rootDir + 16, id: 3, child: type3Dir, isDir: true)
        entry(rootDir + 24, id: 14, child: type14Dir, isDir: true)

        dir(type3Dir, idEntries: n)
        for i in 0..<n { entry(type3Dir + 16 + i * 8, id: UInt32(icons[i].id), child: iconNameDir[i], isDir: true) }
        dir(type14Dir, idEntries: 1)
        entry(type14Dir + 16, id: groupID, child: groupNameDir, isDir: true)

        for i in 0..<n {
            dir(iconNameDir[i], idEntries: 1); entry(iconNameDir[i] + 16, id: lang, child: iconLangDir[i], isDir: true)
            dir(iconLangDir[i], idEntries: 1); entry(iconLangDir[i] + 16, id: lang, child: iconData[i], isDir: false)
            data(iconData[i], at: iconImage[i], size: icons[i].image.count)
            for (j, byte) in icons[i].image.enumerated() { sec[iconImage[i] + j] = byte }
        }
        dir(groupNameDir, idEntries: 1); entry(groupNameDir + 16, id: lang, child: groupLangDir, isDir: true)
        dir(groupLangDir, idEntries: 1); entry(groupLangDir + 16, id: lang, child: groupData, isDir: false)
        data(groupData, at: grpiconDir, size: 6 + n * 14)

        u16(grpiconDir + 2, 1); u16(grpiconDir + 4, UInt16(n))   // GRPICONDIR: type=1, count=n
        for i in 0..<n {
            let e = grpiconDir + 6 + i * 14
            sec[e] = icons[i].width; sec[e + 1] = icons[i].height
            u16(e + 4, 1); u16(e + 6, icons[i].bitCount)
            u32(e + 8, UInt32(icons[i].image.count)); u16(e + 12, icons[i].id)
        }

        // PE headers: DOS ('MZ' + e_lfanew) → PE header → COFF (1 section, no optional header) → section table.
        var pe = [UInt8](repeating: 0, count: sectionBase)
        pe[0] = 0x4D; pe[1] = 0x5A
        func pu16(_ o: Int, _ v: UInt16) { pe[o] = UInt8(v & 0xFF); pe[o + 1] = UInt8(v >> 8) }
        func pu32(_ o: Int, _ v: UInt32) {
            pe[o] = UInt8(v & 0xFF); pe[o + 1] = UInt8((v >> 8) & 0xFF)
            pe[o + 2] = UInt8((v >> 16) & 0xFF); pe[o + 3] = UInt8((v >> 24) & 0xFF)
        }
        pu32(0x3C, 0x40)            // e_lfanew → PE header at 0x40
        pu32(0x40, 0x0000_4550)    // 'PE\0\0'
        let coff = 0x44
        pu16(coff + 2, 1)          // NumberOfSections
        pu16(coff + 16, 0)         // SizeOfOptionalHeader
        let table = coff + 20
        for (k, c) in [UInt8](".rsrc".utf8).enumerated() { pe[table + k] = c }
        pu32(table + 8, UInt32(sectionSize))    // VirtualSize
        pu32(table + 12, UInt32(va))            // VirtualAddress
        pu32(table + 16, UInt32(sectionSize))   // SizeOfRawData
        pu32(table + 20, UInt32(sectionBase))   // PointerToRawData

        return Data(pe + sec)
    }
}
