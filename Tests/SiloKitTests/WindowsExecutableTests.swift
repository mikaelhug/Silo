import Foundation
import Testing
@testable import SiloKit

@Suite("WindowsExecutable")
struct WindowsExecutableTests {

    /// Craft a minimal-but-valid PE: "MZ" DOS header, e_lfanew → PE header, "PE\0\0" + the COFF Machine word.
    private func makePE(machine: UInt16, peOffset: Int = 0x40) -> Data {
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

    private func write(_ data: Data, _ tmp: TempDir, _ name: String) throws -> URL {
        let url = tmp.url.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test("reads the PE machine type: i386 / amd64 / arm64")
    func machineTypes() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        #expect(WindowsExecutable.machine(of: try write(makePE(machine: 0x014c), tmp, "x86.exe")) == .i386)
        #expect(WindowsExecutable.machine(of: try write(makePE(machine: 0x8664), tmp, "x64.exe")) == .amd64)
        #expect(WindowsExecutable.machine(of: try write(makePE(machine: 0xAA64), tmp, "arm.exe")) == .arm64)
    }

    @Test("is32Bit is true ONLY for a confirmed i386 PE (Overcooked 2's case)")
    func is32Bit() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        #expect(WindowsExecutable.is32Bit(try write(makePE(machine: 0x014c), tmp, "x86.exe")))
        #expect(!WindowsExecutable.is32Bit(try write(makePE(machine: 0x8664), tmp, "x64.exe")))
    }

    @Test("fails OPEN: a non-PE / unreadable file returns nil (never false-positives a 32-bit refusal)")
    func failsOpen() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        // Not a PE (no MZ) → nil, so is32Bit is false (don't block a launch on a file we can't parse).
        #expect(WindowsExecutable.machine(of: try write(Data("not an exe".utf8), tmp, "junk.exe")) == nil)
        #expect(!WindowsExecutable.is32Bit(try write(Data("not an exe".utf8), tmp, "junk2.exe")))
        // A valid MZ but a bogus e_lfanew pointing past EOF → nil, not a crash.
        var truncated = makePE(machine: 0x014c); truncated[0x3C] = 0xFF
        #expect(WindowsExecutable.machine(of: try write(truncated, tmp, "trunc.exe")) == nil)
        // Missing file → nil.
        #expect(WindowsExecutable.machine(of: tmp.url.appendingPathComponent("nope.exe")) == nil)
    }
}
