import Foundation

/// Detects when the requested translation layer (GPTK / D3DMetal **or** DXMT) did NOT drive a launch and
/// wine silently fell back to its own `wined3d` (which can't create a modern D3D device on Apple Silicon).
/// This is the guardrail for the exact failure class that previously went unnoticed: the launch "succeeds"
/// (a process spawns), the status bar says "Launched …", but graphics never came up on the chosen backend.
///
/// Detection is a pure parse over the game's launch log, so it unit-tests with fixture text and no runtime.
public enum GraphicsFallback: Sendable {
    public enum Status: Sendable, Equatable {
        case engaged    // POSITIVE proof the requested backend created its device — a later stray wined3d
                        // line is then noise, not a fallback. Only DXMT logs such a line; GPTK/D3DMetal
                        // success is SILENT (a healthy GPTK launch is confirmed only by the absence of the
                        // fallback signatures below), so a GPTK launch never reaches `.engaged`.
        case fallback   // the backend didn't engage — wine's own wined3d was left driving d3d1x (and, for
                        // the titles this happens to, then fails to create the device)
        case unknown    // no decisive signal (a working launch, a d3d9/OpenGL game, or not yet logged)
    }

    /// Signatures that POSITIVELY confirm the backend created its Metal device. GPTK/D3DMetal prints nothing
    /// on success (its only proof is the *absence* of the fallback signatures), so it has none. DXMT logs its
    /// device creation, which lets a DXMT launch be confirmed rather than merely "not-yet-failed" — so a
    /// later benign wined3d line can't produce a false fallback. (Exact DXMT string to reconfirm on-device.)
    static func engagementSignatures(_ backend: GraphicsBackend) -> [String] {
        switch backend {
        case .gptk: []
        case .dxmt: ["DXMT: created Metal device"]
        // DXVK logs the feature level it settled on the moment it creates the D3D device — captured on-device
        // 2026-08-04: `D3D11CoreCreateDevice: Using feature level D3D_FEATURE_LEVEL_11_0` (DXVK 1.10.3). The
        // substring stops before the level itself so any level (11_1/11_0/10_1/…) counts, and before the
        // `D3D11CoreCreateDevice`/`D3D11InternalCreateDevice` prefix, which differs across DXVK versions.
        // Distinct from the failure line ("Requested feature level not supported"), so no false positives.
        case .dxvk: ["Using feature level D3D_FEATURE_LEVEL"]
        }
    }

    /// Signatures that mean wine's own `wined3d` was left driving d3d1x — i.e. the requested backend did
    /// NOT engage (and Silo has no fallback that makes this work; it usually fails device creation).
    /// **Backend-agnostic:** GPTK and DXMT target Metal, so a Vulkan-renderer / feature-level-unsupported line
    /// means neither did its job and wined3d is driving d3d1x. It's a valid fallback signal for DXVK too: when
    /// native DXVK loads it IS the d3d1x provider (wined3d isn't involved, so this line never appears), so the
    /// line appears only when DXVK FAILED to load and wine fell back to its builtin wined3d — again a
    /// non-engagement. A healthy launch — and a legitimate OpenGL game that never touches d3d1x — emits NONE
    /// of these, so no false positives.
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
        // DXVK that loads but can't create a device on the Vulkan driver says so explicitly — captured
        // on-device 2026-08-04 (this is what a STOCK MoltenVK produces at every feature level). Both the
        // 1.x and 2.x wordings are matched. Earlier + far more specific than the generic wined3d signals.
        case .dxvk: [
            "Requested feature level not supported",     // DXVK 1.x: probed every level, none worked
            "Minimum required feature level",            // DXVK 2.x: "…D3D_FEATURE_LEVEL_9_1 not supported"
            "Maximum supported feature level: 0",        // DXVK 2.x: the driver exposed nothing usable
        ]
        }
    }

    /// Classify a launch-log tail for the backend the game was launched under. Pure; case-insensitive.
    /// Positive confirmation wins: if the backend logged that it created its device, a later benign wined3d
    /// line is treated as noise, not a fallback.
    public static func classify(_ log: String, backend: GraphicsBackend = .gptk) -> Status {
        for signature in engagementSignatures(backend) where log.range(of: signature, options: .caseInsensitive) != nil {
            return .engaged
        }
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
    private var autoStop: Task<Void, Never>?
    /// A backend engages (or falls back) within the first seconds of a launch — the signature never appears
    /// later. So after a bounded window, release the kqueue fd even if nothing fired, rather than holding it
    /// for the whole app lifetime on every healthy launch (a per-launch fd leak). Injectable for tests.
    var observationWindow: Duration = .seconds(120)

    /// Whether a kqueue watch is currently armed (test/introspection hook).
    var isObserving: Bool { watch != nil }

    func start(url: URL, backend: GraphicsBackend = .gptk, onFallback: @escaping @MainActor () -> Void) {
        stop()
        self.onFallback = onFallback
        self.backend = backend
        fired = false
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        check(url.tailString())
        // If the fallback signature is already in the log, `check` fired + tore down — don't then arm a
        // watch we don't need (it would sit holding a live kqueue fd until the monitor is dropped).
        guard !fired else { return }
        watch = FileWatch(url: url) {
            let tail = url.tailString()                                  // read off the main actor
            Task { @MainActor [weak self] in self?.check(tail) }
        }
        // Bound the watch's lifetime: a healthy launch never fires, so without this the fd leaks until the
        // owning VM drops the monitor (i.e. never, within a session). Self-cancels on fire/stop.
        autoStop = Task { [weak self, observationWindow] in
            try? await Task.sleep(for: observationWindow)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() { watch = nil; onFallback = nil; autoStop?.cancel(); autoStop = nil }

    private func check(_ tail: String) {
        guard !fired else { return }
        switch GraphicsFallback.classify(tail, backend: backend) {
        case .engaged:
            // Confirmed engaged — tear the watch down so a later benign wined3d line can't fire a false
            // fallback. `fired` also stops `start` from arming a watch after an immediate engaged tail.
            fired = true
            stop()
        case .fallback:
            fired = true
            let callback = onFallback
            stop()
            callback?()
        case .unknown:
            break
        }
    }
}
