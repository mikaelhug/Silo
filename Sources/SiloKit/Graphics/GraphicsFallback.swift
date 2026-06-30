import Foundation

/// Detects when GPTK / D3DMetal did NOT drive a launch and wine silently fell back to its own `wined3d`
/// (which can't create a modern D3D device on Apple Silicon). This is the guardrail for the exact failure
/// class that previously went unnoticed: the launch "succeeds" (a process spawns), the status bar says
/// "Launched …", but graphics never came up on GPTK. We surface it instead of letting it hide.
///
/// Detection is a pure parse over the game's launch log, so it unit-tests with fixture text and no runtime.
public enum GraphicsFallback: Sendable {
    public enum Status: Sendable, Equatable {
        case fallback   // GPTK didn't engage — wine fell back to wined3d (and couldn't create the device)
        case unknown    // no decisive signal (working GPTK launch, a d3d9/OpenGL game, or not yet logged)
    }

    /// Substrings that appear in a launch log ONLY when GPTK/D3DMetal failed to drive d3d10/11/12 and wine
    /// fell back. High-confidence: a working GPTK launch — and a legitimate d3d9/OpenGL game that never
    /// touches d3d1x — emits NONE of these, so the guardrail won't false-positive on them.
    static let fallbackSignatures = [
        "Failed to dlopen D3DMetal",                                 // GPTK's Metal backend never loaded
        "None of the requested D3D feature levels is supported",     // wined3d couldn't create the d3d1x device
    ]

    /// Classify a launch-log tail. Pure; case-insensitive substring match.
    public static func classify(_ log: String) -> Status {
        for signature in fallbackSignatures where log.range(of: signature, options: .caseInsensitive) != nil {
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
    private var fired = false

    func start(url: URL, onFallback: @escaping @MainActor () -> Void) {
        stop()
        self.onFallback = onFallback
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
        guard !fired, GraphicsFallback.classify(tail) == .fallback else { return }
        fired = true
        let callback = onFallback
        stop()
        callback?()
    }
}
