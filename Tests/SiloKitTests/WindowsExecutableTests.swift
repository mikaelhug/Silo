import Foundation
import Testing
@testable import SiloKit

@Suite("WindowsExecutable")
struct WindowsExecutableTests {

    private func write(_ data: Data, _ tmp: TempDir, _ name: String) throws -> URL {
        try PEFixture.write(data, into: tmp, name)
    }

    @Test("reads the PE machine type: i386 / amd64 / arm64")
    func machineTypes() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        #expect(WindowsExecutable.machine(of: try write(PEFixture.header(machine: 0x014c), tmp, "x86.exe")) == .i386)
        #expect(WindowsExecutable.machine(of: try write(PEFixture.header(machine: 0x8664), tmp, "x64.exe")) == .amd64)
        #expect(WindowsExecutable.machine(of: try write(PEFixture.header(machine: 0xAA64), tmp, "arm.exe")) == .arm64)
    }

    @Test("is32Bit is true ONLY for a confirmed i386 PE (Overcooked 2's case)")
    func is32Bit() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        #expect(WindowsExecutable.is32Bit(try write(PEFixture.header(machine: 0x014c), tmp, "x86.exe")))
        #expect(!WindowsExecutable.is32Bit(try write(PEFixture.header(machine: 0x8664), tmp, "x64.exe")))
    }

    @Test("importedDLLs reads DELAY-loaded DLLs too (index-13 directory), lowercased")
    func delayImportsRead() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let x64 = try write(PEFixture.withDelayImports(magic: 0x20b, machine: 0x8664,
                                                       imports: ["D3D12.dll", "kernel32.dll"]), tmp, "delay.exe")
        #expect(WindowsExecutable.importedDLLs(of: x64) == ["d3d12.dll", "kernel32.dll"])
    }

    @Test("fails OPEN: a non-PE / unreadable file returns nil (never false-positives a 32-bit refusal)")
    func failsOpen() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        // Not a PE (no MZ) → nil, so is32Bit is false (don't block a launch on a file we can't parse).
        #expect(WindowsExecutable.machine(of: try write(Data("not an exe".utf8), tmp, "junk.exe")) == nil)
        #expect(!WindowsExecutable.is32Bit(try write(Data("not an exe".utf8), tmp, "junk2.exe")))
        // A valid MZ but a bogus e_lfanew pointing past EOF → nil, not a crash.
        var truncated = PEFixture.header(machine: 0x014c); truncated[0x3C] = 0xFF
        #expect(WindowsExecutable.machine(of: try write(truncated, tmp, "trunc.exe")) == nil)
        // Missing file → nil.
        #expect(WindowsExecutable.machine(of: tmp.url.appendingPathComponent("nope.exe")) == nil)
    }
}
