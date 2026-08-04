import Foundation
import Testing
@testable import SiloKit

@Suite("GraphicsBackend")
struct GraphicsBackendTests {

    @Test("GPTK overrides the full D3DMetal set incl. d3d12 and ships an external framework")
    func gptkShape() {
        #expect(GraphicsBackend.gptk.dllOverrides == "d3d9,d3d10,d3d10_1,d3d10core,d3d11,d3d12,d3d12core,dxgi=b")
        #expect(GraphicsBackend.gptk.overlaysExternalFramework)   // D3DMetal.framework lives in lib/external
    }

    @Test("DXMT overrides d3d9/10/11 + its winemetal bridge, no d3d12, no external framework")
    func dxmtShape() {
        #expect(GraphicsBackend.dxmt.dllOverrides == "d3d9,d3d10,d3d10_1,d3d10core,d3d11,dxgi,winemetal=b")
        #expect(!GraphicsBackend.dxmt.dllOverrides.contains("d3d12"))   // DXMT is D3D10/11 only
        // d3d9 is named so DXVK's permanently-seeded native d3d9 can't be picked up by a DXMT launch —
        // it forces wine's builtin (wined3d), which is the correct answer for a DX9 game here.
        #expect(GraphicsBackend.dxmt.dllOverrides.contains("d3d9"))
        #expect(GraphicsBackend.dxmt.dllOverrides.contains("winemetal"))
        #expect(!GraphicsBackend.dxmt.overlaysExternalFramework)        // winemetal.so links system Metal
    }

    @Test("DXVK overrides d3d9/10core/11 + its own dxgi as NATIVE — the only DX9 path — no framework")
    func dxvkShape() {
        // Native (upstream) DXVK, seeded into the prefix — so `=n`, NOT the `=b` builtin GPTK/DXMT use; and it
        // ships its OWN dxgi (upstream d3d11 is coupled to it), unlike CrossOver's patched wine-dxgi reuse.
        #expect(GraphicsBackend.dxvk.dllOverrides == "d3d9,d3d10core,d3d11,dxgi=n")
        #expect(GraphicsBackend.dxvk.dllOverrides.contains("d3d9"))     // DXVK is the sole DirectX 9 translator
        #expect(GraphicsBackend.dxvk.dllOverrides.contains("dxgi"))     // upstream DXVK's d3d11 needs DXVK's dxgi
        #expect(!GraphicsBackend.dxvk.dllOverrides.contains("d3d12"))   // DX12 stays GPTK
        #expect(!GraphicsBackend.dxvk.overlaysExternalFramework)        // reuses the runtime's bundled MoltenVK
    }

    @Test("Each backend's override set is non-empty and all three are distinct")
    func overridesDistinct() {
        for backend in GraphicsBackend.allCases { #expect(!backend.dllOverrides.isEmpty) }
        let overrides = GraphicsBackend.allCases.map(\.dllOverrides)
        #expect(Set(overrides).count == overrides.count)   // no two backends share an override set
    }

    @Test("Codable round-trips via stable rawValues (config.json forward/back compatibility)")
    func codableRoundTrip() throws {
        #expect(GraphicsBackend.gptk.rawValue == "gptk")
        #expect(GraphicsBackend.dxmt.rawValue == "dxmt")
        #expect(GraphicsBackend.dxvk.rawValue == "dxvk")
        for backend in GraphicsBackend.allCases {
            let data = try JSONEncoder().encode(backend)
            #expect(try JSONDecoder().decode(GraphicsBackend.self, from: data) == backend)
        }
    }

    @Test("GPTK is the first case (the default backend) and UI labels are populated")
    func uiMetadata() {
        #expect(GraphicsBackend.allCases.first == .gptk)
        for backend in GraphicsBackend.allCases {
            #expect(!backend.displayName.isEmpty)
            #expect(!backend.badge.isEmpty)
            #expect(!backend.recommendedFor.isEmpty)
        }
    }
}
