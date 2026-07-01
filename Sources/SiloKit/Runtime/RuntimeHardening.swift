import Foundation

/// The result of a best-effort hardening pass over an extracted runtime tree. Hardening never throws (a
/// codesign hiccup must not fail a 250 MB install), but callers surface `issue(for:)` so a Gatekeeper
/// block shows up as a warning at install time instead of a cryptic launch failure later.
struct HardeningOutcome: Sendable, Equatable {
    var quarantineCleared: Bool
    /// nil = re-signing wasn't attempted (`reSign: false`).
    var signed: Bool?

    /// A user-facing warning naming what failed, or nil when the pass applied cleanly.
    func issue(for dir: URL) -> String? {
        var failed: [String] = []
        if !quarantineCleared { failed.append("clear macOS quarantine on") }
        if signed == false { failed.append("re-sign") }
        guard !failed.isEmpty else { return nil }
        return "Couldn't \(failed.joined(separator: " or ")) \(dir.lastPathComponent) — "
            + "macOS Gatekeeper may refuse to run it."
    }
}

/// De-quarantine an extracted runtime tree (and optionally ad-hoc re-sign) so macOS will run it.
/// Best-effort: failures land in the outcome, never a throw. (`xattr -dr` exits 0 when nothing is
/// quarantined — verified — so a non-zero exit here is a real failure worth warning about.)
@discardableResult
func deQuarantine(_ dir: URL, reSign: Bool, using runner: ProcessRunning) async -> HardeningOutcome {
    let xattr = try? await runner.run(executable: URL(fileURLWithPath: "/usr/bin/xattr"), arguments: ["-dr", "com.apple.quarantine", dir.path], environment: [:], currentDirectory: nil)
    var outcome = HardeningOutcome(quarantineCleared: xattr?.succeeded == true, signed: nil)
    if reSign {
        let sign = try? await runner.run(executable: URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "--sign", "-", "--deep", dir.path], environment: [:], currentDirectory: nil)
        outcome.signed = sign?.succeeded == true
    }
    return outcome
}
