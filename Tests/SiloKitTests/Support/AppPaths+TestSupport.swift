import Foundation
@testable import SiloKit

extension AppPaths {
    /// Create a WARMED Steam client on disk — steamui.dll + a CEF steamwebhelper.exe (what
    /// `SteamBottle.hasWarmedClient` / `steamReady` key on), not just the ~2 MB bootstrapper. Test-only.
    func createWarmedSteamClient() {
        let fm = FileManager.default
        let client = steamBottleClientDir
        try? fm.createDirectory(at: client, withIntermediateDirectories: true)
        fm.createFile(atPath: steamBottleExe.path, contents: Data())
        fm.createFile(atPath: client.appendingPathComponent("steamui.dll").path, contents: Data())
        let cef = steamBottleCEFDir.appendingPathComponent("cef.win7x64")
        try? fm.createDirectory(at: cef, withIntermediateDirectories: true)
        fm.createFile(atPath: cef.appendingPathComponent("steamwebhelper.exe").path, contents: Data())
        // Core-fonts marker so setUp() skips installCoreFonts (which would hit the real network in tests).
        let fonts = steamBottle.appendingPathComponent("drive_c/windows/Fonts")
        try? fm.createDirectory(at: fonts, withIntermediateDirectories: true)
        fm.createFile(atPath: fonts.appendingPathComponent("Arial.TTF").path, contents: Data())
    }
}
