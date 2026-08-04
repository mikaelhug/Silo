import Foundation
import Testing
@testable import SiloKit

/// A game that saved a resolution this Mac cannot produce (Alien Swarm ships 640x480; a Retina display
/// offers no such mode) quits on `EnterFullscreenMode`. Wine's virtual desktop satisfies the mode change
/// itself, so the fix is a launch wrapper — not `-windowed`, and NOT another graphics backend.
@Suite("Virtual-desktop fallback")
struct VirtualDesktopFallbackTests {

    /// Captured verbatim from Alien Swarm's DXVK log.
    private let failed = """
    info:  Setting display mode: 640x480@0
    err:   D3D9: EnterFullscreenMode: Failed to change display mode
    err:   D3D9: Failed to set initial fullscreen state
    """

    @Test("the display-mode failure is detected, and a healthy fullscreen launch is not")
    func detectsOnlyTheFailure() {
        #expect(GraphicsFallback.requestedUnavailableDisplayMode(failed))
        // Measured on-device: fullscreen at a mode the display DOES offer succeeds and logs no error.
        #expect(!GraphicsFallback.requestedUnavailableDisplayMode("info:  Setting display mode: 1512x982@120"))
        #expect(!GraphicsFallback.requestedUnavailableDisplayMode(""))
    }

    /// It must NOT be mistaken for a backend problem — rerouting DXVK→anything cannot help, and DXVK is
    /// the only backend that can run these DirectX 9 games at all.
    @Test("a display-mode failure is not a graphics fallback")
    func notAGraphicsFallback() {
        #expect(GraphicsFallback.classify(failed, backend: .dxvk) != .fallback)
    }

    @Test("the wrapper runs the game inside wine's desktop, preserving its own arguments")
    func wrapsTheInvocation() {
        let exe = URL(fileURLWithPath: "/games/Alien Swarm/swarm.exe")
        let plain = LaunchOrchestrator.invocation(for: exe)
        #expect(plain == [exe.path])
        let wrapped = LaunchOrchestrator.invocation(for: exe, virtualDesktop: true)
        #expect(wrapped.first == "explorer")
        #expect(wrapped.contains { $0.hasPrefix("/desktop=Silo,") })
        #expect(wrapped.last == exe.path)      // the game stays the final argument
    }
}

/// Silo's launch logs APPEND across runs. Reading the whole file would re-detect a one-off failure forever,
/// so the check must look only at the most recent launch.
@Suite("Launch log sectioning")
struct LaunchLogSectionTests {

    @Test("only the last launch is considered, so a fixed game stops being pinned")
    func lastSectionOnly() {
        let log = """
        ===== Silo launch @ 2026-08-04 17:09:04 =====
        err:   D3D9: EnterFullscreenMode: Failed to change display mode
        ===== Silo launch @ 2026-08-04 18:00:00 =====
        info:  Setting display mode: 1512x982@120
        """
        let last = LaunchPlan.lastLaunchSection(of: log)
        #expect(!last.contains("Failed to change display mode"))
        #expect(!GraphicsFallback.requestedUnavailableDisplayMode(last))
        // …and a log whose LAST run failed is still caught.
        let stillFailing = log + "\n===== Silo launch @ 2026-08-04 19:00:00 =====\nerr:   D3D9: EnterFullscreenMode: Failed to change display mode"
        #expect(GraphicsFallback.requestedUnavailableDisplayMode(LaunchPlan.lastLaunchSection(of: stillFailing)))
    }

    @Test("a log with no header is returned whole")
    func noHeader() {
        #expect(LaunchPlan.lastLaunchSection(of: "some old log") == "some old log")
        #expect(LaunchPlan.lastLaunchSection(of: "").isEmpty)
    }
}
