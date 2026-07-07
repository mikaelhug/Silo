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

    /// Create a WARMED Steam client on disk for `backend` — steamui.dll + a CEF steamwebhelper.exe (what
    /// `SteamBottle.hasWarmedClient` / `steamReady` key on), not just the ~2 MB bootstrapper. Test-only.
    func createWarmedSteamClient(_ backend: GraphicsBackend = .gptk) {
        let fm = FileManager.default
        let client = steamBottleClientDir(backend)
        try? fm.createDirectory(at: client, withIntermediateDirectories: true)
        fm.createFile(atPath: steamBottleExe(backend).path, contents: Data())
        fm.createFile(atPath: client.appendingPathComponent("steamui.dll").path, contents: Data())
        let cef = steamBottleCEFDir(backend).appendingPathComponent("cef.win7x64")
        try? fm.createDirectory(at: cef, withIntermediateDirectories: true)
        fm.createFile(atPath: cef.appendingPathComponent("steamwebhelper.exe").path, contents: Data())
        // Core-fonts marker so setUp() skips installCoreFonts (which would hit the real network in tests).
        let fonts = steamBottle(backend).appendingPathComponent("drive_c/windows/Fonts")
        try? fm.createDirectory(at: fonts, withIntermediateDirectories: true)
        fm.createFile(atPath: fonts.appendingPathComponent("Arial.TTF").path, contents: Data())
    }
}
