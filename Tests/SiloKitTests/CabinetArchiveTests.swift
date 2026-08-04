import Foundation
import Testing
@testable import SiloKit

@Suite("Cabinet archive")
struct CabinetArchiveTests {

    @Test("extracts the requested member, not its neighbours")
    func extractsNamedMember() {
        let cab = CabinetBuilder.build([
            .init(name: "first", bytes: Data(repeating: 0xA1, count: 100)),
            .init(name: "wanted", bytes: Data(repeating: 0xB2, count: 40_000)),   // spans a block boundary
            .init(name: "last", bytes: Data(repeating: 0xC3, count: 100)),
        ])
        let out = CabinetArchive.extract(member: "wanted", from: cab)
        #expect(out?.count == 40_000)
        #expect(out?.allSatisfy { $0 == 0xB2 } == true)
        #expect(CabinetArchive.extract(member: "first", from: cab)?.count == 100)
        #expect(CabinetArchive.extract(member: "absent", from: cab) == nil)
    }

    /// The Windows SDK cabinets set RESERVE_PRESENT, which shifts where the folder, file table and every data
    /// block begin. Ignoring it misreads every subsequent offset — silently, since the result is still
    /// *some* bytes — so this must be covered explicitly.
    @Test("honours the RESERVE_PRESENT header layout the SDK cabinets use")
    func honoursHeaderReserve() {
        let members: [CabinetBuilder.Member] = [.init(name: "m", bytes: Data(repeating: 0x7E, count: 5_000))]
        let plain = CabinetArchive.extract(member: "m", from: CabinetBuilder.build(members))
        let reserved = CabinetArchive.extract(member: "m", from: CabinetBuilder.build(members, headerReserve: 20))
        #expect(plain == reserved)
        #expect(reserved?.count == 5_000)
    }

    /// Setup must never crash on a bad download — a truncated or non-cabinet file fails the component and
    /// the user is told, which is the whole point of `unsatisfiedComponents()`.
    @Test("malformed input returns nil rather than trapping")
    func malformedInputFailsSafely() {
        let good = CabinetBuilder.build([.init(name: "m", bytes: Data(repeating: 1, count: 5_000))])
        #expect(CabinetArchive.extract(member: "m", from: Data()) == nil)
        #expect(CabinetArchive.extract(member: "m", from: Data("not a cabinet at all".utf8)) == nil)
        #expect(CabinetArchive.extract(member: "m", from: good.prefix(30)) == nil)          // short header
        #expect(CabinetArchive.extract(member: "m", from: good.prefix(good.count / 2)) == nil) // truncated data
    }
}

/// MSZIP's defining behaviour — a block's DEFLATE stream back-referencing the PREVIOUS block's output —
/// can only be produced by a real MSZIP compressor, so it is verified against **Microsoft's own cabinets**
/// rather than anything this repo generates. Opt-in, because it needs files that exist only on a machine
/// with a provisioned bottle:
///     SILO_BOTTLE_REPORT=1 Scripts/test.sh --filter CabinetArchiveReal
@Suite("Cabinet archive — real Microsoft cabinets (on-device)")
struct CabinetArchiveRealTests {
    static var enabled: Bool { ProcessInfo.processInfo.environment["SILO_BOTTLE_REPORT"] == "1" }

    @Test("multi-block MSZIP cabinets from Microsoft extract to valid PE files",
          .enabled(if: CabinetArchiveRealTests.enabled))
    func realMicrosoftCabinets() throws {
        let redist = AppPaths.standard().steamBottle.appendingPathComponent(
            "drive_c/Program Files (x86)/Steam/steamapps/common/Steamworks Shared/_CommonRedist/DirectX/Jun2010")
        let cabs = ((try? FileManager.default.contentsOfDirectory(at: redist, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "cab" }
        try #require(!cabs.isEmpty, "no Microsoft cabinets on this machine")

        var checked = 0, skippedLZX = 0, blocksSeen = 0
        for url in cabs {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            // Microsoft ships these in a mix of MSZIP and LZX; Silo implements MSZIP only (which is what the
            // Windows SDK cabinets it actually installs from use), so LZX ones are skipped — and COUNTED, so
            // a run that quietly checked nothing can't look like a pass.
            let (compression, blocks) = Self.folderInfo(of: data)
            guard compression == 1 else { skippedLZX += 1; continue }
            blocksSeen = max(blocksSeen, blocks)
            for member in Self.memberNames(of: data) {
                guard let out = CabinetArchive.extract(member: member, from: data) else {
                    Issue.record("failed to extract \(member) from \(url.lastPathComponent)"); continue
                }
                #expect(!out.isEmpty)
                if member.lowercased().hasSuffix(".dll") || member.lowercased().hasSuffix(".exe") {
                    #expect(out.prefix(2) == Data("MZ".utf8), "\(member) is not a PE")
                }
                checked += 1
            }
        }
        #expect(checked > 0, "no members were extracted")
        // The point of this test is the cross-block dictionary, so at least one cabinet must be multi-block.
        #expect(blocksSeen > 1, "no multi-block cabinet was exercised")
        print("CabinetArchive: extracted \(checked) members from Microsoft MSZIP cabinets "
              + "(largest \(blocksSeen) blocks; skipped \(skippedLZX) LZX cabinets)")
    }

    /// The folder's (compression, blockCount), read independently of `CabinetArchive`.
    static func folderInfo(of cab: Data) -> (compression: Int, blocks: Int) {
        guard cab.count > 44 else { return (-1, 0) }
        func u16(_ i: Int) -> Int { Int(cab[cab.startIndex + i]) | Int(cab[cab.startIndex + i + 1]) << 8 }
        var o = 36
        if u16(30) & 0x0004 != 0 { o = 40 + u16(36) }
        guard cab.count > o + 8 else { return (-1, 0) }
        return (u16(o + 6) & 0x0f, u16(o + 4))
    }

    /// Minimal CFFILE-table walk, independent of `CabinetArchive`, so the test names members on its own.
    static func memberNames(of cab: Data) -> [String] {
        guard cab.count > 36, cab.prefix(4) == Data("MSCF".utf8) else { return [] }
        func u16(_ i: Int) -> Int { Int(cab[cab.startIndex + i]) | Int(cab[cab.startIndex + i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        var cursor = u32(16)
        var names: [String] = []
        for _ in 0..<u16(28) {
            guard cab.count > cursor + 16 else { break }
            var end = cab.startIndex + cursor + 16
            while end < cab.endIndex, cab[end] != 0 { end += 1 }
            names.append(String(decoding: cab[(cab.startIndex + cursor + 16)..<end], as: UTF8.self))
            cursor = end - cab.startIndex + 1
        }
        return names
    }
}
