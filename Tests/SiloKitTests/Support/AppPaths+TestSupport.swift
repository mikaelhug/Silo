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

    /// Drop the markers for the NON-Steam bottle components (Core Fonts, Source Han Sans, d3dcompiler_47,
    /// MSVC x86/x64) so `provisionComponents` skips them — leaving only the Steam client to install. Lets a
    /// `setUp` test exercise the Steam path without downloading ~360 MB of fonts etc. Test-only. (Mirrors
    /// `SteamBottle`'s predicates: `Arial.TTF`, `.silo-fonts-installed/<pack>`, `d3dcompiler_47.dll`,
    /// `msvcp140.dll`.)
    func createComponentMarkers() {
        let fm = FileManager.default
        let driveC = steamBottle.appendingPathComponent("drive_c")
        let fonts = driveC.appendingPathComponent("windows/Fonts")
        try? fm.createDirectory(at: fonts, withIntermediateDirectories: true)
        fm.createFile(atPath: fonts.appendingPathComponent("Arial.TTF").path, contents: Data())   // coreFonts
        let markers = steamBottle.appendingPathComponent(".silo-fonts-installed")
        try? fm.createDirectory(at: markers, withIntermediateDirectories: true)
        for pack in Silo.sourceHanSansPacks {
            fm.createFile(atPath: markers.appendingPathComponent(pack).path, contents: Data())      // sourceHanSans
        }
        for dir in ["windows/system32", "windows/syswow64"] {
            let d = driveC.appendingPathComponent(dir)
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
            fm.createFile(atPath: d.appendingPathComponent("d3dcompiler_47.dll").path, contents: Data())  // d3dcompiler
            fm.createFile(atPath: d.appendingPathComponent("msvcp140.dll").path, contents: Data())        // vcRedist
        }
    }
}
