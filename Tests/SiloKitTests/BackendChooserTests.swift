import Foundation
import Testing
@testable import SiloKit

@Suite("BackendChooser + PE imports")
struct BackendChooserTests {

    private func writePE(_ tmp: TempDir, _ name: String, magic: UInt16, machine: UInt16, imports: [String]) throws -> URL {
        try PEFixture.write(PEFixture.withImports(magic: magic, machine: machine, imports: imports), into: tmp, name)
    }

    // MARK: - PE import reader

    @Test("importedDLLs reads the import table for PE32+ and PE32, lowercased")
    func importsRead() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let x64 = try writePE(tmp, "a.exe", magic: 0x20b, machine: 0x8664, imports: ["d3d11.dll", "KERNEL32.dll"])
        #expect(WindowsExecutable.importedDLLs(of: x64) == ["d3d11.dll", "kernel32.dll"])
        let x86 = try writePE(tmp, "b.exe", magic: 0x10b, machine: 0x014c, imports: ["D3D9.dll"])
        #expect(WindowsExecutable.importedDLLs(of: x86) == ["d3d9.dll"])
    }

    @Test("importedDLLs fails open on a non-PE / malformed file (empty set)")
    func importsFailOpen() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let junk = tmp.url.appendingPathComponent("junk.bin")
        try Data([0x4D, 0x5A, 0x00, 0x01, 0x02, 0x03]).write(to: junk)     // "MZ" then garbage
        #expect(WindowsExecutable.importedDLLs(of: junk).isEmpty)
        #expect(WindowsExecutable.importedDLLs(of: tmp.url.appendingPathComponent("missing.exe")).isEmpty)
    }

    // MARK: - choose() (pure — bitness in, backend out)

    @Test("explicit choices are honored regardless of bitness — and win over a learned hint")
    func chooseExplicit() {
        #expect(BackendChooser.choose(.gptk, is32Bit: true) == .gptk)
        #expect(BackendChooser.choose(.dxmt, is32Bit: false) == .dxmt)
        // A user's pin always beats a reactively-learned hint (which only applies to `.auto`).
        #expect(BackendChooser.choose(.gptk, is32Bit: false, learned: .dxmt) == .gptk)
    }

    @Test("auto: 64-bit → GPTK, 32-bit → DXMT")
    func chooseAuto() {
        #expect(BackendChooser.choose(.auto, is32Bit: false) == .gptk)
        #expect(BackendChooser.choose(.auto, is32Bit: true) == .dxmt)   // GPTK is 64-bit-only
    }

    @Test("auto: a learned hint is consulted for a 64-bit launch")
    func chooseLearnedConsulted64BitAutoOnly() {
        #expect(BackendChooser.choose(.auto, is32Bit: false, learned: .dxmt) == .dxmt)  // 64-bit auto uses the hint
        #expect(BackendChooser.choose(.auto, is32Bit: false, learned: nil) == .gptk)    // no hint → GPTK default
        #expect(BackendChooser.choose(.auto, is32Bit: false, learned: .gptk) == .gptk)  // defensive: hint agrees
        #expect(BackendChooser.choose(.auto, is32Bit: true, learned: .dxmt) == .dxmt)   // 32-bit hint agrees
    }

    @Test("auto 32-bit HONOURS a learned DXVK hint — else the DXMT→DXVK reroute loops forever")
    func choose32BitHonoursLearnedDXVK() {
        // Regression: DXMT and DXVK BOTH ship i386 modules, so a 32-bit game DXMT can't drive learns `.dxvk`.
        // Ignoring the hint here sent it back to DXMT every launch while the status bar promised DXVK —
        // an unbounded loop with a config write per launch, invisible because the message was always right.
        #expect(BackendChooser.choose(.auto, is32Bit: true, learned: .dxvk) == .dxvk)
        // A `.gptk` hint is never valid for a 32-bit game (GPTK is 64-bit-only) → DXMT.
        #expect(BackendChooser.choose(.auto, is32Bit: true, learned: .gptk) == .dxmt)
        // An explicit pin still wins.
        #expect(BackendChooser.choose(.dxmt, is32Bit: true, learned: .dxvk) == .dxmt)
    }

    // MARK: - The ladder gates (pure — one D3DProfile drives GPTK → DXMT → DXVK)

    @Test("dxmtMightHelp: D3D10/11 → yes; D3D12 or D3D9-only → no; unknown → yes (permissive)")
    func mightHelp() {
        #expect(BackendChooser.dxmtMightHelp(profile: D3DProfile(usesD3D1x: true)))
        #expect(!BackendChooser.dxmtMightHelp(profile: D3DProfile(usesD3D12: true)))                  // needs D3D12
        #expect(!BackendChooser.dxmtMightHelp(profile: D3DProfile(usesD3D9: true)))                   // D3D9-only
        #expect(BackendChooser.dxmtMightHelp(profile: D3DProfile(usesD3D9: true, usesD3D1x: true)))   // has D3D10/11
        #expect(BackendChooser.dxmtMightHelp(profile: D3DProfile()))                                  // unknown → try
    }

    @Test("dxvkMightHelp: D3D9/10/11 → yes; pure D3D12 → no; unknown → yes (broadest net)")
    func dxvkMightHelp() {
        #expect(BackendChooser.dxvkMightHelp(profile: D3DProfile(usesD3D9: true)))     // DXVK does DX9
        #expect(BackendChooser.dxvkMightHelp(profile: D3DProfile(usesD3D1x: true)))    // and DX10/11
        #expect(BackendChooser.dxvkMightHelp(profile: D3DProfile()))                   // unknown → try
        #expect(!BackendChooser.dxvkMightHelp(profile: D3DProfile(usesD3D12: true)))   // pure D3D12 → can't
        // D3D12 alongside D3D11 → DXVK could still drive the d3d11 path, so it's worth trying.
        #expect(BackendChooser.dxvkMightHelp(profile: D3DProfile(usesD3D1x: true, usesD3D12: true)))
    }

    // MARK: - DX9-first routing

    @Test("auto + DX9-only → DXVK, regardless of bitness and even over a learned hint")
    func chooseDX9FirstToDXVK() {
        let dx9 = D3DProfile(usesD3D9: true)
        #expect(BackendChooser.choose(.auto, is32Bit: false, profile: dx9) == .dxvk)   // 64-bit DX9 → DXVK
        #expect(BackendChooser.choose(.auto, is32Bit: true, profile: dx9) == .dxvk)    // 32-bit DX9 → DXVK (not DXMT)
        // DX9 wins over a stale learned DXMT hint (a DX9 title should never have learned DXMT, but be safe).
        #expect(BackendChooser.choose(.auto, is32Bit: false, profile: dx9, learned: .dxmt) == .dxvk)
        // An explicit pin still wins over DX9-first (the user asked for it).
        #expect(BackendChooser.choose(.gptk, is32Bit: false, profile: dx9) == .gptk)
        // A game that ALSO uses D3D10/11 is NOT DX9-only → normal GPTK-first path (no needless Vulkan hop).
        let mixed = D3DProfile(usesD3D9: true, usesD3D1x: true)
        #expect(BackendChooser.choose(.auto, is32Bit: false, profile: mixed) == .gptk)
        #expect(BackendChooser.choose(.auto, is32Bit: true, profile: mixed) == .dxmt)
        // Unknown profile (dynamic loader) → the normal path, never a speculative DXVK route.
        #expect(BackendChooser.choose(.auto, is32Bit: false, profile: D3DProfile()) == .gptk)
        #expect(BackendChooser.choose(.auto, is32Bit: true, profile: D3DProfile()) == .dxmt)
    }
}
