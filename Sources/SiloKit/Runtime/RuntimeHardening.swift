import Foundation

/// The result of de-quarantining an extracted runtime tree. It never throws (a hiccup must not fail a
/// 250 MB install); callers surface `issue(for:)` so a real Gatekeeper block shows up as a warning at
/// install time instead of a cryptic launch failure later.
struct HardeningOutcome: Sendable, Equatable {
    var quarantineCleared: Bool

    /// A user-facing warning when de-quarantine failed, or nil when it applied cleanly.
    func issue(for dir: URL) -> String? {
        guard !quarantineCleared else { return nil }
        return "Couldn't clear macOS quarantine on \(dir.lastPathComponent) — "
            + "Gatekeeper may refuse to run it."
    }
}

/// Strip the `com.apple.quarantine` flag from an extracted runtime tree so macOS will run it — the one
/// load-bearing step for a downloaded runtime. Best-effort: a failure lands in the outcome, never a
/// throw. (`xattr -dr` exits 0 when nothing is quarantined, so a non-zero exit is a real failure.)
///
/// We deliberately do NOT ad-hoc re-sign. The runtimes are plain x86_64 Mach-O trees run under Rosetta,
/// which macOS executes unsigned (only arm64 requires a signature); GPTK's D3DMetal is Apple-signed and
/// must keep its signature; and `codesign --deep` can't sign a non-bundle directory anyway.
@discardableResult
func deQuarantine(_ dir: URL, using runner: ProcessRunning) async -> HardeningOutcome {
    let xattr = try? await runner.run(
        executable: URL(fileURLWithPath: "/usr/bin/xattr"),
        arguments: ["-dr", "com.apple.quarantine", dir.path],
        environment: [:], currentDirectory: nil)
    return HardeningOutcome(quarantineCleared: xattr?.succeeded == true)
}
