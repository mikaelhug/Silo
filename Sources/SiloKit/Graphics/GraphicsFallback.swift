import Foundation

/// Detects when the requested translation layer (GPTK / D3DMetal **or** DXMT) did NOT drive a launch and
/// wine silently fell back to its own `wined3d` (which can't create a modern D3D device on Apple Silicon).
/// This is the guardrail for the exact failure class that previously went unnoticed: the launch "succeeds"
/// (a process spawns), the status bar says "Launched …", but graphics never came up on the chosen backend.
///
/// Detection is a pure parse over the game's launch log, so it unit-tests with fixture text and no runtime.
public enum GraphicsFallback: Sendable {
    public enum Status: Sendable, Equatable {
        case fallback   // the backend didn't engage — wine fell back to wined3d (and couldn't create the device)
        case unknown    // no decisive signal (a working launch, a d3d9/OpenGL game, or not yet logged)
    }

    /// Signatures that mean wine's own `wined3d` took over rendering — i.e. the requested backend did NOT
    /// engage. **Backend-agnostic:** both GPTK and DXMT target Metal, so a Vulkan-renderer / feature-level-
    /// unsupported line means neither did its job and wined3d is driving d3d1x. A healthy launch — and a
    /// legitimate d3d9/OpenGL game that never touches d3d1x — emits NONE of these, so no false positives.
    static let wined3dFallbackSignatures = [
        "None of the requested D3D feature levels is supported",     // wined3d couldn't create the d3d1x device
        "Using the Vulkan renderer",                                 // wined3d IS driving d3d1x (the definitive
                                                                     // "the backend didn't engage" signal,
                                                                     // present even when wined3d then runs OK)
    ]

    /// Backend-specific signatures that pinpoint *that* layer's loader failing — earlier + more specific
    /// than the generic wined3d signals. GPTK logs a D3DMetal dlopen assertion; DXMT has no
    /// reliably-distinct early signature yet (a bare "winemetal" appears on healthy launches too, so it
    /// can't be one), so it relies on the wined3d signals above. Verify a DXMT-specific string on-device.
    static func loaderFailureSignatures(_ backend: GraphicsBackend) -> [String] {
        switch backend {
        case .gptk: ["Failed to dlopen D3DMetal"]   // GPTK's Metal backend never loaded
        case .dxmt: []
        }
    }

    /// Classify a launch-log tail for the backend the game was launched under. Pure; case-insensitive.
    public static func classify(_ log: String, backend: GraphicsBackend = .gptk) -> Status {
        let signatures = wined3dFallbackSignatures + loaderFailureSignatures(backend)
        for signature in signatures where log.range(of: signature, options: .caseInsensitive) != nil {
            return .fallback
        }
        return .unknown
    }
}

/// Watches a game's launch log and fires `onFallback` ONCE if the GPTK→wined3d fallback signature appears.
/// kqueue-based (reuses `FileWatch`), no polling; reads the current tail immediately (a fast graphics
/// failure may already be written) then on each write, and tears itself down on the first hit or on `stop`.
@MainActor
final class GraphicsFallbackMonitor {
    private var watch: FileWatch?
    private var onFallback: (@MainActor () -> Void)?
    private var backend: GraphicsBackend = .gptk
    private var fired = false

    func start(url: URL, backend: GraphicsBackend = .gptk, onFallback: @escaping @MainActor () -> Void) {
        stop()
        self.onFallback = onFallback
        self.backend = backend
        fired = false
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        check(url.tailString())
        watch = FileWatch(url: url) {
            let tail = url.tailString()                                  // read off the main actor
            Task { @MainActor [weak self] in self?.check(tail) }
        }
    }

    func stop() { watch = nil; onFallback = nil }

    private func check(_ tail: String) {
        guard !fired, GraphicsFallback.classify(tail, backend: backend) == .fallback else { return }
        fired = true
        let callback = onFallback
        stop()
        callback?()
    }
}
