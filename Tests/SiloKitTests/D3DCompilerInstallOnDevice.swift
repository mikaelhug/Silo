import Foundation
import Testing
@testable import SiloKit

/// Runs the REAL `d3dcompiler_47` component against the REAL bottle on this machine — download, SHA
/// verification, cabinet extraction and both-ABI install, through production code with nothing faked.
///
/// Separately gated from the read-only reports (`SILO_INSTALL_D3DCOMPILER=1`) because it is the only check
/// here that WRITES to the user's bottle. It exists because the component had never once been executed
/// end-to-end: the extractor was proven against Microsoft's cabinets and the install was proven against
/// synthetic ones, and a bug living in the seam between them would have shipped unnoticed — which is exactly
/// how the original `wine expand` failure survived.
@Suite("d3dcompiler_47 install (on-device, writes to the bottle)")
struct D3DCompilerInstallOnDevice {
    static var enabled: Bool { ProcessInfo.processInfo.environment["SILO_INSTALL_D3DCOMPILER"] == "1" }

    @Test("the component installs Microsoft's DLL into the real bottle",
          .enabled(if: D3DCompilerInstallOnDevice.enabled))
    func installsForReal() async throws {
        let paths = AppPaths.standard()
        let bottle = SteamBottle(runner: SystemProcessRunner(), paths: paths)
        let driveC = paths.steamBottle.appendingPathComponent("drive_c")
        func size(_ abi: String) -> Int {
            let u = driveC.appendingPathComponent("windows/\(abi)/d3dcompiler_47.dll")
            return (try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? Int ?? 0
        }
        print("\nbefore: system32=\(size("system32")) syswow64=\(size("syswow64")) satisfied=\(bottle.hasD3DCompiler47)")

        try await bottle.installD3DCompiler47(downloads: bottle.startSetupDownloads())

        print("after:  system32=\(size("system32")) syswow64=\(size("syswow64")) satisfied=\(bottle.hasD3DCompiler47)")
        // Microsoft's DLL is ~4 MB per ABI; wine's builtin (what was there) is ~371 KB / ~325 KB.
        #expect(size("system32") > 3_000_000)
        #expect(size("syswow64") > 3_000_000)
        #expect(bottle.hasD3DCompiler47)
        #expect(!bottle.unsatisfiedComponents().contains(.d3dcompiler47))
    }
}
