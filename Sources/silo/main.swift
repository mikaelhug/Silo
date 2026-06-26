import Foundation
import SiloKit

setbuf(stdout, nil)   // unbuffered so progress shows immediately under non-TTY

// Headless smoke mode for CI / sandboxes that can't open a window.
if CommandLine.arguments.contains("--smoke")
    || ProcessInfo.processInfo.environment["SILO_SMOKE"] == "1" {
    print("\(Silo.appName) \(Silo.version) — smoke ok")
} else if let idx = CommandLine.arguments.firstIndex(of: "--import-gptk"),
          idx + 1 < CommandLine.arguments.count {
    // CLI: import GPTK from an Apple .dmg (same code path the GUI uses). Top-level await — no
    // Task+semaphore (that pattern deadlocks the main thread in a CLI).
    let dmg = URL(fileURLWithPath: CommandLine.arguments[idx + 1])
    print("Importing GPTK from \(dmg.path)")
    do {
        let result = try await GPTKImporter(runner: SystemProcessRunner(), paths: .standard())
            .importGPTK(fromDMG: dmg) { stage in print("• \(stage)") }
        print("Imported GPTK:")
        print("  install dir:  \(result.installDir.path)")
        print("  gptk lib dir: \(result.gptkLibDir.path)")
        print("  D3DMetal:     \(result.d3dMetalFramework.path)")
    } catch {
        print("GPTK import failed: \(error)")
        exit(1)
    }
} else {
    SiloApp.main()
}
