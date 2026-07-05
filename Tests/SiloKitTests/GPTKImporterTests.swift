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
        // Two real GPTK installs (overlay tree, no wine binary)…
        for name in ["GPTK-4.0", "GPTK-3.1"] {
            try tmp.write("Silo/Runtimes/\(name)/lib/wine/x86_64-windows/d3d11.dll", "x")
            try tmp.makeDir("Silo/Runtimes/\(name)/lib/external/D3DMetal.framework")
        }
        // …plus an OVERLAID wine runtime: it ALSO carries lib/external/D3DMetal.framework + d3d modules
        // (GraphicsLinker.overlayGPTK copies them in), so it must be distinguished by its wine binary and
        // NOT listed as GPTK.
        try tmp.write("Silo/Runtimes/wine-cx-26.2.0/lib/wine/x86_64-windows/d3d11.dll", "x")
        try tmp.makeDir("Silo/Runtimes/wine-cx-26.2.0/lib/external/D3DMetal.framework")
        try tmp.write("Silo/Runtimes/wine-cx-26.2.0/bin/wine64", "x")

        let importer = GPTKImporter(runner: FakeProcessRunner(), paths: paths)
        #expect(importer.installed().map(\.name) == ["GPTK-3.1", "GPTK-4.0"])   // GPTK-only (wine excluded)

        try importer.remove(name: "GPTK-3.1")
        #expect(importer.installed().map(\.name) == ["GPTK-4.0"])
    }

    @Test("a failed de-quarantine fires onWarning naming the install (import still succeeds)")
    func importWarnsOnHardeningFailure() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let eval = try makeEvalMount(tmp, named: "flatMount")   // flat layout: single attach
        let fake = FakeProcessRunner()
        fake.queueResult(attachPlist(mountPoint: eval.path))    // attach ok
        fake.queueResult(ProcessResult(exitCode: 1))            // xattr fails (there is no codesign step)
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let warning = LockedBox<String?>(nil)
        let result = try await GPTKImporter(runner: fake, paths: paths).importGPTK(
            fromDMG: tmp.url.appendingPathComponent("GPTK.dmg"), name: "GPTK-warn",
            onWarning: { warning.set($0) })
        #expect(result.name == "GPTK-warn")   // non-fatal: the import completed
        let message = try #require(warning.value)
        #expect(message.contains("quarantine") && message.contains("GPTK-warn"))
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

        // GPTK is de-quarantined so the D3DMetal libs load...
        #expect(fake.invocations.contains {
            $0.executable.lastPathComponent == "xattr" && $0.arguments.contains("com.apple.quarantine")
        })
        // ...but NEVER re-signed: preserve Apple's D3DMetal signature (nothing runs codesign).
        #expect(!fake.invocations.contains { $0.executable.lastPathComponent == "codesign" })
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

        // The atomic-publish staging dir is cleaned up — no leftover `.gptk-import-*` sibling.
        let runtimeChildren = try FileManager.default.contentsOfDirectory(atPath: paths.runtimesDir.path)
        #expect(!runtimeChildren.contains { $0.hasPrefix(".gptk-import-") })
    }

    @Test("A failure during publish leaves no partial install and no staging dir")
    func atomicImportNoPartialOnFailure() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let mount = try makeEvalMount(tmp, named: "failMount")
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))

        // Pre-create the final install dir as a NON-EMPTY, read-only obstacle so the post-copy
        // `removeItem(installDir)` + `moveItem(staging → installDir)` publish step throws AFTER the copy
        // and de-quarantine already succeeded — exercising the staging-cleanup guarantee.
        let installDir = paths.runtimesDir.appendingPathComponent("GPTK-fail", isDirectory: true)
        try FileManager.default.createDirectory(
            at: installDir.appendingPathComponent("locked"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: installDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installDir.path) }

        let fake = FakeProcessRunner()
        fake.queueResult(attachPlist(mountPoint: mount.path))
        do {
            _ = try await GPTKImporter(runner: fake, paths: paths)
                .importGPTK(fromDMG: tmp.url.appendingPathComponent("GPTK.dmg"), name: "GPTK-fail")
            Issue.record("expected the publish step to throw")
        } catch {
            // expected — the read-only installDir blocks the remove/move publish.
        }
        // Cleanup ran: no `.gptk-import-*` staging sibling left behind.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installDir.path)
        let children = try FileManager.default.contentsOfDirectory(atPath: paths.runtimesDir.path)
        #expect(!children.contains { $0.hasPrefix(".gptk-import-") })
    }

    @Test("Throws attachFailed (with stderr) when hdiutil attach fails")
    func attachFailure() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let fake = FakeProcessRunner()
        fake.queueResult(ProcessResult(exitCode: 1, standardError: Data("hdiutil: corrupt image".utf8)))
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        do {
            _ = try await GPTKImporter(runner: fake, paths: paths)
                .importGPTK(fromDMG: tmp.url.appendingPathComponent("Bad.dmg"))
            Issue.record("expected importGPTK to throw")
        } catch let GPTKImporter.ImportError.attachFailed(message) {
            #expect(message.contains("corrupt image"))
        }
        // Attach was attempted but failed → nothing to detach.
        #expect(fake.invocations.filter { $0.arguments.contains("attach") }.count == 1)
        #expect(fake.invocations.filter { $0.arguments.contains("detach") }.isEmpty)
    }

    @Test("Throws redistNotFound and detaches BOTH mounts when the eval volume lacks redist/lib")
    func redistNotFoundDetachesBoth() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        // Outer mount: no redist, but a nested Evaluation dmg → triggers the inner attach.
        let outer = try tmp.makeDir("outerMount2")
        try tmp.write("outerMount2/Evaluation environment for Windows games.dmg", "nested")
        // Inner mount: present but WITHOUT redist/lib → redistNotFound.
        let eval = try tmp.makeDir("evalMount2")

        let fake = FakeProcessRunner()
        fake.queueResult(attachPlist(mountPoint: outer.path))   // 1st attach → outer
        fake.queueResult(attachPlist(mountPoint: eval.path))    // 2nd attach → inner (no redist)

        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        await #expect(throws: GPTKImporter.ImportError.redistNotFound) {
            try await GPTKImporter(runner: fake, paths: paths)
                .importGPTK(fromDMG: tmp.url.appendingPathComponent("GPTK.dmg"))
        }
        // Both mounts were cleaned up via the do/catch detachAll.
        #expect(fake.invocations.filter { $0.arguments.contains("attach") }.count == 2)
        #expect(fake.invocations.filter { $0.arguments.contains("detach") }.count == 2)
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
