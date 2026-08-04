import Foundation
import Testing
@testable import SiloKit

/// `GraphicsFallback` decides whether a backend engaged, and that decision drives the reactive
/// GPTK → DXMT → DXVK ladder. Its signatures are string matches against real logs, so they are only as good
/// as the logs they were derived from — and two of them had been *invented* rather than observed, which is
/// exactly the failure mode that shipped 0.4.5. Every fixture here is a verbatim excerpt of a launch log
/// Silo itself wrote on a real bottle (2026-08-04), so these pin observed behaviour, not an assumption.
@Suite("Graphics fallback — real launch logs")
struct GraphicsFallbackRealLogTests {

    /// REGRESSION: GPTK had NO engagement signature, so a working GPTK launch could never be confirmed —
    /// only inferred from the absence of failure. D3DMetal's spoofed "AMD Compatibility Mode" adapter is
    /// positive proof, and this is the real line Bloons TD 6 logged under GPTK.
    @Test("a real GPTK launch is positively recognised as engaged")
    func realGPTKLogIsEngaged() throws {
        let log = try FixtureLoader.text("log_gptk_engaged_real.txt")
        #expect(GraphicsFallback.classify(log, backend: .gptk) == .engaged)
    }

    /// REGRESSION: DXMT's signature was `"DXMT: created Metal device"` — a string that appears ZERO times in
    /// this log, which is a successful DXMT launch (device created at feature level 11_1). DXMT is a DXVK
    /// fork and inherits DXVK's logger wording.
    @Test("a real DXMT launch is positively recognised as engaged")
    func realDXMTLogIsEngaged() throws {
        let log = try FixtureLoader.text("log_dxmt_engaged_real.txt")
        #expect(!log.contains("DXMT: created Metal device"))   // the string that was assumed, and is absent
        #expect(GraphicsFallback.classify(log, backend: .dxmt) == .engaged)
    }

    /// The other direction, from a real log where GPTK's overrides WERE requested but wine's own wined3d
    /// ended up driving d3d1x — a genuine non-engagement, and the case the ladder exists to react to.
    @Test("a real wined3d takeover is recognised as a fallback")
    func realWined3dLogIsFallback() throws {
        let log = try FixtureLoader.text("log_wined3d_fallback_real.txt")
        #expect(GraphicsFallback.classify(log, backend: .gptk) == .fallback)
    }

    /// The signatures must not cross-talk: each real log is decisive ONLY for the backend that produced it,
    /// so a mislabelled launch can never be read as a success.
    @Test("engagement proof for one backend is not proof for another")
    func signaturesDoNotCrossTalk() throws {
        let gptk = try FixtureLoader.text("log_gptk_engaged_real.txt")
        let dxmt = try FixtureLoader.text("log_dxmt_engaged_real.txt")
        #expect(GraphicsFallback.classify(gptk, backend: .dxmt) != .engaged)
        #expect(GraphicsFallback.classify(dxmt, backend: .gptk) != .engaged)
    }

    /// REGRESSION, from a real DirectX 9 launch that FAILED (Double Action: Boogaloo / Alien Swarm, 2026-08-04).
    /// `"Device properties:"` was listed as DXVK engagement proof on the reasoning that DXVK logs it only
    /// after `vkCreateDevice` succeeds. It does not — DXVK prints its whole adapter report while ENUMERATING.
    /// Since `classify` gives engagement precedence, a hard device-creation failure reported `.engaged`, and
    /// the on-device report cheerfully showed two dead games as working.
    @Test("a real DXVK device-creation failure is a fallback, never engaged")
    func realDXVKDeviceFailureIsFallback() throws {
        let log = try FixtureLoader.text("log_dxvk_device_failure_real.txt")
        #expect(log.contains("Device properties:"))          // the misleading line IS present…
        #expect(log.contains("Failed to create device"))     // …alongside the actual failure
        #expect(GraphicsFallback.classify(log, backend: .dxvk) == .fallback)
        #expect(GraphicsFallback.classify(log, backend: .dxvk) != .engaged)
    }
}
