import Compression
import Foundation

/// A minimal reader for Microsoft Cabinet (`.cab`) archives — enough to pull ONE named member out of a
/// single-folder MSZIP cabinet, which is exactly the shape of the Windows SDK cabinets Silo installs
/// `d3dcompiler_47.dll` from.
///
/// **Why this exists instead of `wine expand`.** Silo used to shell out to `wine expand <cab> -F:<member> …`.
/// Wine's `expand` does not implement that: its usage is `expand infile outfile` / `expand /r infile` — a
/// SZDD/KWAJ decompressor, with no cabinet-member extraction and no `-F:` flag. It ignored the arguments,
/// exited **0**, and wrote nothing, so the component silently never installed Microsoft's DLL on any machine
/// (confirmed on-device 2026-08-04: the bottle's `d3dcompiler_47.dll` was byte-identical to wine's own
/// builtin). Doing it natively is both correct and simpler — no wine process, no prefix, no exit code to
/// misread, and it works before `wineboot` has ever run.
///
/// Pure and synchronous, so it unit-tests instantly. Every parse step is bounds-checked and returns `nil`
/// rather than trapping: a truncated or unexpected cabinet must fail the component, never crash setup.
enum CabinetArchive {

    /// Extract a single member by name. Returns `nil` if the cabinet is malformed, uses a compression other
    /// than NONE/MSZIP, or has no such member.
    static func extract(member wanted: String, from cab: Data) -> Data? {
        guard cab.count >= 36, cab.prefix(4) == Data("MSCF".utf8) else { return nil }

        let coffFiles = Int(cab.u32(16))
        let cFolders = Int(cab.u16(26))
        let cFiles = Int(cab.u16(28))
        let flags = cab.u16(30)
        guard cFolders >= 1, cFiles >= 1 else { return nil }

        // CFHEADER is 36 bytes, optionally followed by the reserve descriptor + per-cabinet reserve bytes.
        // The per-FOLDER and per-DATA reserve sizes declared here also pad every CFFOLDER and CFDATA below —
        // the Windows SDK cabinets DO set this flag, so skipping it silently misreads every later offset.
        // (The per-FOLDER reserve size at byte 38 pads each CFFOLDER *after* the first; only CFFOLDER[0] is
        // read here, and it sits immediately after the header, so it needs no adjustment.)
        var cursor = 36
        var dataReserve = 0
        if flags & 0x0004 != 0 {
            guard cab.count >= 40 else { return nil }
            let headerReserve = Int(cab.u16(36))
            dataReserve = Int(cab.u8(39))
            cursor = 40 + headerReserve
        }

        // CFFOLDER[0] — Silo only needs single-folder cabinets, which is what the SDK ships.
        guard cab.count >= cursor + 8 else { return nil }
        let firstDataOffset = Int(cab.u32(cursor))
        let blockCount = Int(cab.u16(cursor + 4))
        let compression = cab.u16(cursor + 6) & 0x000f

        // CFFILE table — find the member and its offset WITHIN the folder's uncompressed stream.
        var fileCursor = coffFiles
        var found: (offset: Int, size: Int)?
        for _ in 0..<cFiles {
            guard cab.count >= fileCursor + 16 else { return nil }
            let size = Int(cab.u32(fileCursor))
            let offset = Int(cab.u32(fileCursor + 4))
            guard let end = cab.firstIndexOfZero(from: fileCursor + 16) else { return nil }
            let name = String(decoding: cab[(fileCursor + 16)..<end], as: UTF8.self)
            if name == wanted { found = (offset, size) }
            fileCursor = end + 1
        }
        guard let member = found else { return nil }

        // Only decompress as far as the member actually needs — the wanted DLL is usually not last.
        guard let folder = decompressFolder(cab, firstDataOffset: firstDataOffset, blockCount: blockCount,
                                            compression: compression, dataReserve: dataReserve,
                                            upTo: member.offset + member.size)
        else { return nil }
        guard folder.count >= member.offset + member.size else { return nil }
        return folder[member.offset..<(member.offset + member.size)]
    }

    /// Concatenate + decompress a folder's CFDATA blocks, stopping once `upTo` uncompressed bytes exist.
    private static func decompressFolder(_ cab: Data, firstDataOffset: Int, blockCount: Int,
                                         compression: UInt16, dataReserve: Int, upTo: Int) -> Data? {
        guard compression == 0 || compression == 1 else { return nil }   // NONE or MSZIP only
        var out = Data(), offset = firstDataOffset

        for _ in 0..<blockCount {
            guard cab.count >= offset + 8 else { return nil }
            let compressedSize = Int(cab.u16(offset + 4))
            let uncompressedSize = Int(cab.u16(offset + 6))
            let start = offset + 8 + dataReserve
            guard cab.count >= start + compressedSize else { return nil }
            let block = cab[start..<(start + compressedSize)]

            if compression == 0 {
                out.append(block)
            } else {
                // Each MSZIP block is the two-byte signature "CK" followed by a RAW DEFLATE stream that may
                // back-reference the previous block's output — the format resets the deflate stream per block
                // but keeps the 32 KB history window. Apple's Compression framework has no preset-dictionary
                // API, so the history is supplied IN-BAND: a stored (uncompressed) deflate block carrying the
                // previous 32 KB is prepended, and its bytes are dropped from the result. Correct by
                // construction — a stored block is exactly how DEFLATE represents literal bytes.
                guard block.count >= 2, block.prefix(2) == Data("CK".utf8) else { return nil }
                let history = out.suffix(Self.windowSize)
                var stream = storedBlock(history)
                stream.append(block.dropFirst(2))
                guard let inflated = inflate(stream, capacity: history.count + uncompressedSize),
                      inflated.count >= history.count else { return nil }
                out.append(inflated.dropFirst(history.count))
            }
            offset = start + compressedSize
            if out.count >= upTo { break }
        }
        return out
    }

    /// DEFLATE's 32 KB back-reference window — the most history any block can refer to.
    private static let windowSize = 32_768

    /// Wrap `bytes` as one or more non-final DEFLATE *stored* blocks: a `0x00` header byte (BFINAL=0,
    /// BTYPE=00 stored), then LEN and its one's complement, then the literal bytes.
    private static func storedBlock(_ bytes: Data) -> Data {
        var out = Data()
        var rest = Data(bytes)
        repeat {
            let chunk = rest.prefix(65_535)
            let len = UInt16(chunk.count)
            out.append(0x00)
            out.append(UInt8(len & 0xff)); out.append(UInt8(len >> 8))
            out.append(UInt8(~len & 0xff)); out.append(UInt8((~len >> 8) & 0xff))
            out.append(chunk)
            rest = rest.dropFirst(chunk.count)
        } while !rest.isEmpty
        return out
    }

    /// Raw-DEFLATE decode. `COMPRESSION_ZLIB` is Apple's name for the raw stream (no zlib header), which is
    /// what both MSZIP blocks and the stored prefix above are.
    private static func inflate(_ data: Data, capacity: Int) -> Data? {
        guard capacity > 0 else { return Data() }
        var destination = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBytes { source -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(&destination, capacity, base, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        return Data(destination[0..<written])
    }
}

// MARK: - Bounds-checked little-endian reads

private extension Data {
    func u8(_ i: Int) -> UInt8 { self[startIndex + i] }
    func u16(_ i: Int) -> UInt16 { UInt16(u8(i)) | UInt16(u8(i + 1)) << 8 }
    func u32(_ i: Int) -> UInt32 {
        UInt32(u16(i)) | UInt32(u16(i + 2)) << 16
    }
    /// Index of the NUL terminating a CFFILE name, or `nil` if the table runs off the end.
    func firstIndexOfZero(from: Int) -> Int? {
        var i = startIndex + from
        while i < endIndex {
            if self[i] == 0 { return i - startIndex }
            i += 1
        }
        return nil
    }
}
