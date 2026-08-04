import Foundation
import Testing
@testable import SiloKit

@Suite("D3D profile — redistributable DLLs")
struct D3DProfileRedistTests {

    /// REGRESSION, found by running the on-device backend report against a real Steam library.
    /// Microsoft's C++ AMP runtime (`vcamp140.dll`) — shipped beside the exe by any game that bundles the MSVC
    /// redist — imports `d3d11.dll` for GPU compute. Absorbing it made Bloons TD Battles 2 (a pure OpenGL
    /// title) profile as a D3D10/11 game. The real damage is on DirectX 9: a DX9 game shipping the redist
    /// would fail `isD3D9Only` and be routed away from DXVK, the only backend that can run it.
    @Test("MSVC redistributable DLLs shipped beside the exe are not treated as the game's renderer")
    func msvcRedistributablesAreExcluded() {
        for name in ["vcamp140.dll", "VCAMP140.DLL", "vcomp140.dll", "msvcp140.dll", "vcruntime140_1.dll",
                     "concrt140.dll", "ucrtbase.dll", "api-ms-win-crt-runtime-l1-1-0.dll", "mfc140u.dll",
                     "d3dcompiler_47.dll", "xinput1_3.dll", "xaudio2_9.dll"] {
            #expect(D3DProfile.isRedistributableModule(name), "\(name) is a redistributable, not the renderer")
        }
    }

    /// The other half — the DLLs that genuinely CARRY the renderer must still be scanned. These are the exact
    /// engine modules the scanner exists to find, and a too-eager prefix rule would silently blind it.
    @Test("engine DLLs that carry the renderer are still scanned")
    func engineModulesAreNotExcluded() {
        for name in ["UnityPlayer.dll", "shaderapidx9.dll", "d3d9.dll", "d3d11.dll", "dxgi.dll",
                     "GameOverlayRenderer64.dll", "vulkan-1.dll", "opengl32.dll", "bink2w64.dll"] {
            #expect(!D3DProfile.isRedistributableModule(name), "\(name) must still be scanned")
        }
    }

    /// The routing consequence, stated as the property that actually matters: a DX9 game stays DX9-only, and
    /// therefore still reaches DXVK, no matter what redistributables sit in its folder.
    @Test("a DirectX 9 game still routes to DXVK")
    func dx9GameStillReachesDXVK() {
        let dx9 = D3DProfile(usesD3D9: true)
        #expect(dx9.isD3D9Only)
        #expect(BackendChooser.choose(.auto, is32Bit: false, profile: dx9) == .dxvk)
    }
}
