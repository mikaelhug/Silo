import Foundation

/// Builds a **valid, uncompressed** Microsoft Cabinet in memory, so the cabinet reader and the
/// d3dcompiler component can be tested without shipping a vendor binary in the repo (constraint #7).
///
/// Deliberately covers only `typeCompress = NONE`: an MSZIP cabinet's defining behaviour is that a block's
/// DEFLATE stream back-references the PREVIOUS block's output, and only a real MSZIP compressor emits those.
/// Hand-rolling one here would test the reader against this file's own idea of the format — the circular
/// fixture that let `wine expand` look like it worked for months. MSZIP is verified instead against
/// Microsoft's own cabinets (`CabinetArchiveRealTests`, opt-in).
enum CabinetBuilder {
    struct Member { let name: String, bytes: Data }

    /// `headerReserve` exercises the RESERVE_PRESENT path that the real SDK cabinets use.
    static func build(_ members: [Member], headerReserve: Int = 0) -> Data {
        let blockSize = 32_768
        var folderStream = Data()
        var files = Data()
        for m in members {
            files.append(u32(UInt32(m.bytes.count)))          // cbFile
            files.append(u32(UInt32(folderStream.count)))     // uoffFolderStart
            files.append(u16(0))                              // iFolder
            files.append(u16(0)); files.append(u16(0))        // date, time
            files.append(u16(0x20))                           // attribs
            files.append(Data(m.name.utf8)); files.append(0)  // szName
            folderStream.append(m.bytes)
        }

        var data = Data()
        var blocks = 0
        var rest = folderStream
        while !rest.isEmpty {
            let chunk = rest.prefix(blockSize)
            data.append(u32(0))                               // csum (unchecked)
            data.append(u16(UInt16(chunk.count)))             // cbData
            data.append(u16(UInt16(chunk.count)))             // cbUncomp (NONE ⇒ equal)
            data.append(chunk)
            rest = rest.dropFirst(chunk.count)
            blocks += 1
        }

        let headerSize = headerReserve > 0 ? 40 + headerReserve : 36
        let folderOffset = headerSize
        let filesOffset = folderOffset + 8
        let dataOffset = filesOffset + files.count

        var cab = Data("MSCF".utf8)
        cab.append(u32(0))                                    // reserved1
        cab.append(u32(UInt32(dataOffset + data.count)))      // cbCabinet
        cab.append(u32(0))                                    // reserved2
        cab.append(u32(UInt32(filesOffset)))                  // coffFiles
        cab.append(u32(0))                                    // reserved3
        cab.append(3); cab.append(1)                          // version 1.3
        cab.append(u16(1))                                    // cFolders
        cab.append(u16(UInt16(members.count)))                // cFiles
        cab.append(u16(headerReserve > 0 ? 0x0004 : 0))       // flags
        cab.append(u16(0)); cab.append(u16(0))                // setID, iCabinet
        if headerReserve > 0 {
            cab.append(u16(UInt16(headerReserve)))            // cbCFHeader
            cab.append(0); cab.append(0)                      // cbCFFolder, cbCFData
            cab.append(Data(repeating: 0xAB, count: headerReserve))
        }
        cab.append(u32(UInt32(dataOffset)))                   // CFFOLDER.coffCabStart
        cab.append(u16(UInt16(blocks)))                       // cCFData
        cab.append(u16(0))                                    // typeCompress = NONE
        cab.append(files)
        cab.append(data)
        return cab
    }

    private static func u16(_ v: UInt16) -> Data { Data([UInt8(v & 0xff), UInt8(v >> 8)]) }
    private static func u32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)])
    }
}
