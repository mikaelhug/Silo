import Foundation
import Testing
@testable import SiloKit

@Suite("GPTKImporter")
struct GPTKImporterTests {

    /// A minimal `hdiutil attach -plist` output with one mount-point.
    private func attachPlist(mountPoint: String) -> ProcessResult {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>system-entities</key><array>
          <dict><key>content-hint</key><string>GUID_partition_scheme</string></dict>
          <dict><key>mount-point</key><string>\(mountPoint)</string></dict>
        </array></dict></plist>
        """
        return ProcessResult(exitCode: 0, standardOutput: Data(xml.utf8))
    }

    /// Build a fake mounted "eval environment" with the GPTK redist tree.
    private func makeEvalMount(_ tmp: TempDir, named: String) throws -> URL {
        let base = "\(named)/redist/lib"
        try tmp.write("\(base)/external/libd3dshared.dylib", "DYLIB")
        try tmp.write("\(base)/external/D3DMetal.framework/D3DMetal", "FRAMEWORK")
        for dll in ["d3d11.dll", "d3d12.dll", "dxgi.dll"] {
            try tmp.write("\(base)/wine/x86_64-windows/\(dll)", "DLL")
        }
        try tmp.write("\(base)/wine/x86_64-unix/d3d11.so", "SO")
        return tmp.url.appendingPathComponent(named)
    }

    @Test("Parses the mount point from hdiutil -plist output")
    func mountPointParse() {
        let data = attachPlist(mountPoint: "/Volumes/GPTK").standardOutput
        #expect(GPTKImporter.mountPoint(fromPlist: data)?.path == "/Volumes/GPTK")
        #expect(GPTKImporter.mountPoint(fromPlist: Data("not a plist".utf8)) == nil)
    }

    @Test("Derives a versioned runtime name from the DMG filename")
    func nameDerivation() {
        #expect(GPTKImporter.runtimeName(
            forDMG: URL(fileURLWithPath: "/x/Game_Porting_Toolkit_4.0_beta_1.dmg")) == "GPTK-4.0_beta_1")
        #expect(GPTKImporter.runtimeName(forDMG: URL(fileURLWithPath: "/x/custom.dmg")) == "custom")
    }

    @Test("Lists installed GPTK versions and removes them")
    func installedAndRemove() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        // Two GPTK installs + one non-GPTK dir (should be ignored).
        for name in ["GPTK-4.0", "GPTK-3.1"] {
            try tmp.write("Silo/Runtimes/\(name)/lib/wine/x86_64-windows/d3d11.dll", "x")
            try tmp.makeDir("Silo/Runtimes/\(name)/lib/external/D3DMetal.framework")
        }
        try tmp.write("Silo/Runtimes/wine-only/bin/wine64", "x")   // not a GPTK install

        let importer = GPTKImporter(runner: FakeProcessRunner(), paths: paths)
        #expect(importer.installed().map(\.name) == ["GPTK-3.1", "GPTK-4.0"])   // sorted, GPTK-only

        try importer.remove(name: "GPTK-3.1")
        #expect(importer.installed().map(\.name) == ["GPTK-4.0"])
    }

    @Test("Imports from a nested-DMG layout (GPTK 4.x) and extracts redist/lib")
    func nestedImport() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }

        // Fake outer mount: no redist, but contains a nested "Evaluation environment" dmg file.
        let outer = try tmp.makeDir("outerMount")
        try tmp.write("outerMount/Evaluation environment for Windows games.dmg", "nested")
        // Fake inner mount with the real GPTK tree.
        let eval = try makeEvalMount(tmp, named: "evalMount")

        let fake = FakeProcessRunner()
        fake.queueResult(attachPlist(mountPoint: outer.path))   // 1st attach → outer
        fake.queueResult(attachPlist(mountPoint: eval.path))    // 2nd attach → inner

        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let importer = GPTKImporter(runner: fake, paths: paths)
        let result = try await importer.importGPTK(fromDMG: tmp.url.appendingPathComponent("GPTK.dmg"))

        // D3DMetal DLLs + framework copied into the runtime's lib tree.
        #expect(result.gptkLibDir.lastPathComponent == "x86_64-windows")
        #expect(FileManager.default.fileExists(atPath: result.gptkLibDir.appendingPathComponent("d3d11.dll").path))
        #expect(FileManager.default.fileExists(atPath: result.d3dMetalFramework.appendingPathComponent("D3DMetal").path))
        #expect(FileManager.default.fileExists(
            atPath: paths.runtimesDir.appendingPathComponent("GPTK/lib/external/libd3dshared.dylib").path))

        // Two attaches + two detaches (cleanup).
        #expect(fake.invocations.filter { $0.arguments.contains("attach") }.count == 2)
        #expect(fake.invocations.filter { $0.arguments.contains("detach") }.count == 2)
    }

    @Test("Imports from a single-DMG layout (redist at top level)")
    func flatImport() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let mount = try makeEvalMount(tmp, named: "flatMount")   // redist/lib directly under mount

        let fake = FakeProcessRunner()
        fake.queueResult(attachPlist(mountPoint: mount.path))    // single attach

        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let result = try await GPTKImporter(runner: fake, paths: paths)
            .importGPTK(fromDMG: tmp.url.appendingPathComponent("GPTK.dmg"), name: "GPTK-flat")

        #expect(FileManager.default.fileExists(atPath: result.gptkLibDir.appendingPathComponent("dxgi.dll").path))
        #expect(fake.invocations.filter { $0.arguments.contains("attach") }.count == 1)
        #expect(fake.invocations.filter { $0.arguments.contains("detach") }.count == 1)
    }

    @Test("Throws nestedDMGNotFound when no redist and no inner dmg")
    func noRedist() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let outer = try tmp.makeDir("emptyMount")
        let fake = FakeProcessRunner()
        fake.queueResult(attachPlist(mountPoint: outer.path))
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        await #expect(throws: GPTKImporter.ImportError.nestedDMGNotFound) {
            try await GPTKImporter(runner: fake, paths: paths)
                .importGPTK(fromDMG: tmp.url.appendingPathComponent("GPTK.dmg"))
        }
        // The outer mount is still detached on failure.
        #expect(fake.invocations.filter { $0.arguments.contains("detach") }.count == 1)
    }
}
