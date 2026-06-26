import Foundation
import SiloKit

// Headless smoke mode for CI / sandboxes that can't open a window: verify the binary links
// against SiloKit + SwiftUI and exit. Normal invocation launches the GUI.
if CommandLine.arguments.contains("--smoke")
    || ProcessInfo.processInfo.environment["SILO_SMOKE"] == "1" {
    print("\(Silo.appName) \(Silo.version) — smoke ok")
} else {
    SiloApp.main()
}
