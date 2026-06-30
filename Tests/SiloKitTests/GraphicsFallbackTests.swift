import Foundation
import Testing
@testable import SiloKit

@Suite("GraphicsFallback")
struct GraphicsFallbackTests {

    // Real signatures captured from a live broken launch (GPTK didn't engage → wined3d).
    @Test("flags a D3DMetal dlopen failure as fallback")
    func dlopenFailure() {
        let log = """
        msync: up and running.
        Assertion failed: (GFXTHandle && "Failed to dlopen D3DMetal"), function D3DRMDispatch_Init_block_invoke, file shared.mm, line 1629.
        """
        #expect(GraphicsFallback.classify(log) == .fallback)
    }

    @Test("flags a wined3d feature-level failure as fallback")
    func featureLevelFailure() {
        let log = "fixme:winediag:wined3d_select_feature_level None of the requested D3D feature levels is supported on this GPU with the current shader backend."
        #expect(GraphicsFallback.classify(log) == .fallback)
    }

    @Test("detection is case-insensitive")
    func caseInsensitive() {
        #expect(GraphicsFallback.classify("FAILED TO DLOPEN D3DMETAL") == .fallback)
    }

    @Test("a healthy GPTK launch (or a d3d9/OpenGL game) is NOT flagged")
    func healthyNotFlagged() {
        let log = """
        msync: up and running.
        GPU Apple M4 Pro (Apple)
        OpenGL 2.1 Metal - 90.5
        == application started
        """
        #expect(GraphicsFallback.classify(log) == .unknown)
    }

    @Test("empty / unrelated-noise log is unknown")
    func unknownOnNoise() {
        #expect(GraphicsFallback.classify("") == .unknown)
        #expect(GraphicsFallback.classify("fixme:keyboard:NtUserActivateKeyboardLayout not supported") == .unknown)
    }
}
