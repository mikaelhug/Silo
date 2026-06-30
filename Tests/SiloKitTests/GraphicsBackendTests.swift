import Foundation
import Testing
@testable import SiloKit

@Suite("GraphicsBackend")
struct GraphicsBackendTests {

    @Test("GPTK overrides the full D3DMetal set incl. d3d12 and ships an external framework")
    func gptkShape() {
        #expect(GraphicsBackend.gptk.dllOverrides == "d3d10,d3d10_1,d3d10core,d3d11,d3d12,d3d12core,dxgi=b")
        #expect(GraphicsBackend.gptk.overlaysExternalFramework)   // D3DMetal.framework lives in lib/external
    }

    @Test("DXMT overrides d3d10/11 + its winemetal bridge, no d3d12, no external framework")
    func dxmtShape() {
        #expect(GraphicsBackend.dxmt.dllOverrides == "d3d10core,d3d11,dxgi,winemetal=b")
        #expect(!GraphicsBackend.dxmt.dllOverrides.contains("d3d12"))   // DXMT is D3D10/11 only
        #expect(GraphicsBackend.dxmt.dllOverrides.contains("winemetal"))
        #expect(!GraphicsBackend.dxmt.overlaysExternalFramework)        // winemetal.so links system Metal
    }

    @Test("Each backend's override set is non-empty and the two are distinct")
    func overridesDistinct() {
        for backend in GraphicsBackend.allCases { #expect(!backend.dllOverrides.isEmpty) }
        #expect(GraphicsBackend.gptk.dllOverrides != GraphicsBackend.dxmt.dllOverrides)
    }

    @Test("Codable round-trips via stable rawValues (config.json forward/back compatibility)")
    func codableRoundTrip() throws {
        #expect(GraphicsBackend.gptk.rawValue == "gptk")
        #expect(GraphicsBackend.dxmt.rawValue == "dxmt")
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
