import Foundation

/// De-quarantine an extracted runtime tree (and optionally ad-hoc re-sign) so macOS will run it. Best-effort.
func deQuarantine(_ dir: URL, reSign: Bool, using runner: ProcessRunning) async {
    _ = try? await runner.run(executable: URL(fileURLWithPath: "/usr/bin/xattr"), arguments: ["-dr", "com.apple.quarantine", dir.path], environment: [:], currentDirectory: nil)
    if reSign {
        _ = try? await runner.run(executable: URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "--sign", "-", "--deep", dir.path], environment: [:], currentDirectory: nil)
    }
}
