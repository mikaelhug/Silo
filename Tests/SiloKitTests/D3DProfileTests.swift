import Foundation
import Testing
@testable import SiloKit

@Suite("D3DProfile scan")
struct D3DProfileTests {

    /// Write a PE (exe or dll) with the given imports into `tmp` at `relative`.
    @discardableResult
    private func pe(_ tmp: TempDir, _ relative: String, _ imports: [String],
                    machine: UInt16 = 0x8664) throws -> URL {
        let magic: UInt16 = machine == 0x8664 ? 0x20b : 0x10b
        let dir = (relative as NSString).deletingLastPathComponent
        if !dir.isEmpty { try tmp.makeDir(dir) }
        let url = tmp.url.appendingPathComponent(relative)
        try PEFixture.withImports(magic: magic, machine: machine, imports: imports).write(to: url)
        return url
    }

    @Test("The executable's own imports are read (regular + delay-load)")
    func exeImports() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try pe(tmp, "game/game.exe", ["d3d11.dll", "kernel32.dll"])
        let p = D3DProfile.scan(executable: exe)
        #expect(p.usesD3D1x && !p.usesD3D9 && !p.usesD3D12)
        #expect(!p.isUnknown && !p.isD3D9Only)

        // A DELAY-loaded d3d12 (common) must count too — it's the only place the name appears.
        let delayed = tmp.url.appendingPathComponent("dl/dl.exe")
        try tmp.makeDir("dl")
        try PEFixture.withDelayImports(magic: 0x20b, machine: 0x8664, imports: ["d3d12.dll"]).write(to: delayed)
        #expect(D3DProfile.scan(executable: delayed).usesD3D12)
    }

    @Test("THE FIX: a DX9 renderer in a DLL BESIDE the exe is found (Unity-style stub exe)")
    func rendererInSiblingDLL() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        // Unity ships a thin launcher exe with no D3D imports; the renderer lives in UnityPlayer.dll.
        let exe = try pe(tmp, "game/game.exe", ["kernel32.dll"])
        try pe(tmp, "game/UnityPlayer.dll", ["d3d9.dll"])

        // Scanning the exe ALONE says "unknown" → the game would have taken the GPTK-first path and failed.
        #expect(WindowsExecutable.importedDLLs(of: exe).isDisjoint(with: ["d3d9.dll"]))
        // Scanning the game finds it → routed straight to DXVK, first launch.
        let p = D3DProfile.scan(executable: exe)
        #expect(p.isD3D9Only)
        #expect(BackendChooser.choose(.auto, is32Bit: false, profile: p) == .dxvk)
    }

    @Test("THE FIX: a DX9 renderer one directory DOWN is found (Source-style bin/shaderapidx9.dll)")
    func rendererInSubdirectory() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        // Source: <root>/hl2.exe + <root>/bin/shaderapidx9.dll
        let exe = try pe(tmp, "hl2/hl2.exe", ["kernel32.dll"])
        try pe(tmp, "hl2/bin/shaderapidx9.dll", ["d3d9.dll"])

        let p = D3DProfile.scan(executable: exe)
        #expect(p.isD3D9Only)
        // 32-bit Source games are the classic case — still DXVK, not DXMT (DXMT has no d3d9).
        #expect(BackendChooser.choose(.auto, is32Bit: true, profile: p) == .dxvk)
    }

    @Test("A newer API anywhere in the game keeps it off the DX9 route")
    func newerAPIWins() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try pe(tmp, "g/g.exe", ["d3d9.dll"])        // legacy d3d9 path in the exe…
        try pe(tmp, "g/renderer_dx11.dll", ["d3d11.dll"])     // …but the game also ships a DX11 renderer
        let p = D3DProfile.scan(executable: exe)
        #expect(p.usesD3D9 && p.usesD3D1x)
        #expect(!p.isD3D9Only)                                 // not a pure DX9 title
        #expect(BackendChooser.choose(.auto, is32Bit: false, profile: p) == .gptk)
    }

    @Test("Bundled redistributables are NOT mistaken for the game's own D3D usage")
    func redistDirsExcluded() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try pe(tmp, "g/g.exe", ["d3d9.dll"])
        // A DirectX redist shipped alongside references newer D3D — it must not flip the game off DX9.
        try pe(tmp, "g/_CommonRedist/DirectX/d3dcompiler_helper.dll", ["d3d11.dll", "d3d12.dll"])
        let p = D3DProfile.scan(executable: exe)
        #expect(p.isD3D9Only)
        #expect(!p.usesD3D1x && !p.usesD3D12)
    }

    @Test("A DirectX 8 game is recognised — wined3d is correct, so no backend claims it can help")
    func directX8() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try pe(tmp, "old/old.exe", ["d3d8.dll"], machine: 0x014c)   // DX8 titles are 32-bit
        let p = D3DProfile.scan(executable: exe)
        #expect(p.isD3D8Only && !p.isUnknown && !p.isD3D9Only)
        // Neither rung of the ladder may claim it can help — nothing translates d3d8, so the reroute would
        // be pure churn and the "couldn't drive your graphics" message a lie (wined3d IS driving it).
        #expect(!BackendChooser.dxmtMightHelp(profile: p))
        #expect(!BackendChooser.dxvkMightHelp(profile: p))
        // Routing is unaffected — d3d8 isn't in any backend's override set, so wine's d3d8→wined3d stands.
        #expect(BackendChooser.choose(.auto, is32Bit: true, profile: p) == .dxmt)
    }

    @Test("A d3d8to9-wrapped game reaches DXVK (the wrapper imports d3d9 — the arrangement that works)")
    func d3d8WrappedToD3D9() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try pe(tmp, "w/w.exe", ["d3d8.dll"], machine: 0x014c)
        try pe(tmp, "w/d3d8.dll", ["d3d9.dll"], machine: 0x014c)   // the user-installed d3d8to9 wrapper
        let p = D3DProfile.scan(executable: exe)
        #expect(p.usesD3D8 && p.usesD3D9)
        #expect(!p.isD3D8Only && p.isD3D9Only)                     // now a DX9 title as far as routing goes
        #expect(BackendChooser.choose(.auto, is32Bit: true, profile: p) == .dxvk)
    }

    @Test("A Vulkan-native game routes to DXVK — for its working MoltenVK, not for D3D translation")
    func vulkanNative() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try pe(tmp, "vk/vk.exe", ["vulkan-1.dll", "kernel32.dll"])
        let p = D3DProfile.scan(executable: exe)
        #expect(p.isVulkanNative && !p.isUnknown)
        // The wine runtime's own bundled MoltenVK is the stock one; only the DXVK runtime ships a working
        // driver, and its dir is put first on the launch DYLD path.
        #expect(BackendChooser.choose(.auto, is32Bit: false, profile: p) == .dxvk)
        // A game using Vulkan AND Direct3D is NOT Vulkan-native — the D3D path decides.
        let mixed = try pe(tmp, "vkd/vkd.exe", ["vulkan-1.dll", "d3d11.dll"])
        let pm = D3DProfile.scan(executable: mixed)
        #expect(!pm.isVulkanNative)
        #expect(BackendChooser.choose(.auto, is32Bit: false, profile: pm) == .gptk)
    }

    @Test("An import-less game yields an UNKNOWN profile — fail-open, never a speculative DX9 route")
    func unknownProfile() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try pe(tmp, "g/g.exe", ["kernel32.dll"])
        let p = D3DProfile.scan(executable: exe)
        #expect(p.isUnknown && !p.isD3D9Only)
        #expect(BackendChooser.choose(.auto, is32Bit: false, profile: p) == .gptk)   // normal path
        // Unknown must let BOTH reactive rungs try (the ladder still self-heals).
        #expect(BackendChooser.dxmtMightHelp(profile: p) && BackendChooser.dxvkMightHelp(profile: p))
    }

    @Test("Unreadable/garbage binaries are skipped rather than blocking a launch")
    func failsOpenOnGarbage() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        try tmp.makeDir("g")
        let exe = tmp.url.appendingPathComponent("g/g.exe")
        try Data([0x4D, 0x5A, 0x00, 0x01]).write(to: exe)          // "MZ" then junk
        try tmp.write("g/broken.dll", "not a PE at all")
        let p = D3DProfile.scan(executable: exe)
        #expect(p.isUnknown)                                        // no crash, no hang
        // A missing executable is equally harmless.
        #expect(D3DProfile.scan(executable: tmp.url.appendingPathComponent("g/nope.exe")).isUnknown)
    }
}
