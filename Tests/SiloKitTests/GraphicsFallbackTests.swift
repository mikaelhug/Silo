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

    @Test("flags wined3d driving d3d1x (the definitive 'GPTK didn't engage' signal)")
    func vulkanRenderer() {
        // Real line from Overcooked! 2 (legacy D3D10 path → wined3d, not GPTK).
        let log = "05c4:err:winediag:wined3d_adapter_create Using the Vulkan renderer for d3d10/11 applications."
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

    // MARK: - DXVK (log text captured on-device 2026-08-04, DXVK 1.10.3 + 2.6.2 on MoltenVK)

    @Test("a DXVK launch that created its D3D device is POSITIVELY confirmed as engaged (real captured log)")
    func dxvkEngagedConfirmed() {
        // Verbatim from the successful on-device probe (DXVK 1.10.3 → patched MoltenVK → Metal, M4 Pro).
        let log = """
        info:  DXVK: v1.10.3
        info:  Apple M4 Pro:
        info:    Driver: 0.2.2018
        info:    Vulkan: 1.2.290
        info:  D3D11CoreCreateDevice: Probing D3D_FEATURE_LEVEL_11_0
        info:  D3D11CoreCreateDevice: Using feature level D3D_FEATURE_LEVEL_11_0
        info:  Device properties:
        """
        #expect(GraphicsFallback.classify(log, backend: .dxvk) == .engaged)
    }

    @Test("a DirectX 9 launch under DXVK is detected — engaged AND failed (no d3d11 feature-level line)")
    func dxvkD3D9PathDetected() {
        // A d3d9 game never emits the d3d11 `Using feature level …` line, so the shared
        // `DxvkAdapter::createDevice` logging is the only proof either way. Success:
        let engaged = """
        info:  DXVK: v1.10.3
        info:  Apple M4 Pro:
        info:  Device properties:
        info:    Device name:     : Apple M4 Pro
        """
        #expect(!engaged.contains("Using feature level"))          // the d3d11-only signal is absent…
        #expect(GraphicsFallback.classify(engaged, backend: .dxvk) == .engaged)   // …yet still confirmed

        // Failure: D3D9Interface::CreateDevice catches the DxvkError and logs its message verbatim.
        let failed = """
        info:  DXVK: v1.10.3
        err:   DxvkAdapter: Failed to create device
        """
        #expect(GraphicsFallback.classify(failed, backend: .dxvk) == .fallback)
    }

    @Test("a DXVK launch that could not create a device is flagged (both 1.x and 2.x wordings)")
    func dxvkDeviceCreationFailureDetected() {
        // DXVK 1.x: probes every level, then gives up (what a STOCK MoltenVK produces).
        let v1 = """
        info:  D3D11CoreCreateDevice: Probing D3D_FEATURE_LEVEL_9_1
        err:   D3D11CoreCreateDevice: Requested feature level not supported
        """
        #expect(GraphicsFallback.classify(v1, backend: .dxvk) == .fallback)
        // DXVK 2.x wording.
        let v2 = """
        info:  D3D11InternalCreateDevice: Maximum supported feature level: 0
        err:   D3D11InternalCreateDevice: Minimum required feature level D3D_FEATURE_LEVEL_9_1 not supported
        """
        #expect(GraphicsFallback.classify(v2, backend: .dxvk) == .fallback)
    }

    /// DXMT is a DXVK fork and inherits its logger, so this line is genuine engagement proof for BOTH — as
    /// confirmed against a real DXMT log. That is harmless because `classify` is always given the backend the
    /// launch actually requested; the scoping that has to hold is against GPTK, whose D3DMetal never emits it.
    @Test("a Vulkan-layer engagement line proves the Vulkan-derived backends, never GPTK")
    func engagementLineIsScopedAgainstGPTK() {
        let log = "info:  D3D11CoreCreateDevice: Using feature level D3D_FEATURE_LEVEL_11_0"
        #expect(GraphicsFallback.classify(log, backend: .dxvk) == .engaged)
        #expect(GraphicsFallback.classify(log, backend: .dxmt) == .engaged)   // same logger, same wording
        #expect(GraphicsFallback.classify(log, backend: .gptk) == .unknown)   // D3DMetal never prints this
    }

    @Test("a DXMT launch that fell back to wined3d is flagged via the backend-agnostic signals")
    func dxmtFallbackDetected() {
        let log = "05c4:err:winediag:wined3d_adapter_create Using the Vulkan renderer for d3d10/11 applications."
        #expect(GraphicsFallback.classify(log, backend: .dxmt) == .fallback)
    }

    @Test("a DXMT launch that created its Metal device is POSITIVELY confirmed as engaged")
    func dxmtEngagedConfirmed() {
        let log = """
        msync: up and running.
        trace:module:load_builtin_dll Loaded L"C:\\\\windows\\\\system32\\\\winemetal.dll"
        info:  Maximum supported feature level: D3D_FEATURE_LEVEL_11_1
        info:  Using feature level D3D_FEATURE_LEVEL_11_1
        == application started
        """
        #expect(GraphicsFallback.classify(log, backend: .dxmt) == .engaged)
    }

    @Test("positive engagement WINS over a later stray wined3d line (no false fallback)")
    func engagedBeatsStrayFallbackLine() {
        let log = """
        info:  Maximum supported feature level: D3D_FEATURE_LEVEL_11_1
        info:  Using feature level D3D_FEATURE_LEVEL_11_1
        05c4:err:winediag:wined3d_adapter_create Using the Vulkan renderer for d3d10/11 applications.
        """
        #expect(GraphicsFallback.classify(log, backend: .dxmt) == .engaged)
    }

    /// GPTK is proven by D3DMetal's spoofed "AMD Compatibility Mode" adapter and by nothing else — in
    /// particular not by the Vulkan-derived backends' logger, and not by a launch whose game never logs its
    /// adapter, which stays `.unknown` rather than being read as a failure.
    @Test("GPTK is proven only by D3DMetal's own adapter line, never by another backend's logger")
    func gptkEngagementIsItsOwnSignal() {
        // A DXMT/DXVK device line means nothing under GPTK — D3DMetal does not use that logger.
        #expect(GraphicsFallback.classify("info:  Using feature level D3D_FEATURE_LEVEL_11_1",
                                          backend: .gptk) == .unknown)
        #expect(GraphicsFallback.classify("== application started", backend: .gptk) == .unknown)
        #expect(GraphicsFallback.classify("    Renderer: AMD Compatibility Mode (ID=0x66af)",
                                          backend: .gptk) == .engaged)
    }

    @MainActor
    @Test("the monitor releases its kqueue watch after the observation window on a healthy launch (no fd leak)")
    func monitorReleasesWatchAfterWindow() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let log = try tmp.write("game.log", "loading assets… all good, no fallback here\n")
        let monitor = GraphicsFallbackMonitor()
        monitor.observationWindow = .milliseconds(40)
        var fired = false
        monitor.start(url: log, backend: .gptk) { fired = true }
        #expect(monitor.isObserving)               // armed — no fallback signature in the log yet
        // Poll for the autoStop task to release the fd (bounded; avoids a fixed-sleep flake under load).
        for _ in 0..<200 where monitor.isObserving { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!monitor.isObserving)              // auto-released the fd once the window elapsed
        #expect(!fired)                            // a healthy launch never fires the fallback callback
    }

    @MainActor
    @Test("a confirmed-engaged DXMT launch tears the watch down without firing a false fallback")
    func monitorStopsOnEngagedWithoutFiring() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let log = try tmp.write("game.log", "info:  Using feature level D3D_FEATURE_LEVEL_11_1\n")
        let monitor = GraphicsFallbackMonitor()
        var fired = false
        monitor.start(url: log, backend: .dxmt) { fired = true }
        #expect(!monitor.isObserving)              // the immediate tail check saw engagement → torn down
        #expect(!fired)                            // engaged is NOT a fallback — the callback never fires
        // A later stray wined3d line must not resurrect a fallback (the watch is already gone).
        let h = try FileHandle(forWritingTo: log); h.seekToEndOfFile()
        h.write(Data("05c4:err:winediag:wined3d_adapter_create Using the Vulkan renderer for d3d10/11 applications.".utf8))
        try? h.close()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!fired)
    }
}
