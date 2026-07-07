import Foundation
@testable import SiloKit

/// Test-only shorthands for the GPTK (default/primary) Steam bottle. Production code always names the
/// backend explicitly via the `AppPaths.steamBottle(_:)` family — the shipping type carries no no-arg
/// convenience surface — but the large GPTK-focused test suite stays terse with these. `steamBottleLog`
/// is intentionally omitted: no test needs it (its one production caller passes `.gptk` explicitly).
extension AppPaths {
    var steamBottle: URL { steamBottle(.gptk) }
    var steamBottleClientDir: URL { steamBottleClientDir(.gptk) }
    var steamBottleExe: URL { steamBottleExe(.gptk) }
    var steamBottleCEFDir: URL { steamBottleCEFDir(.gptk) }
}
