import Foundation
import Testing
@testable import SiloKit

@MainActor
@Suite("GPTKManagerViewModel")
struct GPTKManagerViewModelTests {

    private func seedInstall(_ tmp: TempDir, _ name: String) throws {
        try tmp.write("Silo/Runtimes/\(name)/lib/wine/x86_64-windows/d3d11.dll", "x")
        try tmp.makeDir("Silo/Runtimes/\(name)/lib/external/D3DMetal.framework")
    }

    @Test("Refresh lists installed GPTK versions")
    func refresh() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        try seedInstall(tmp, "GPTK-4.0")
        try seedInstall(tmp, "GPTK-3.1")
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let vm = GPTKManagerViewModel(importer: GPTKImporter(runner: FakeProcessRunner(), paths: paths))
        vm.refresh()
        #expect(vm.installs.map(\.name) == ["GPTK-3.1", "GPTK-4.0"])
    }

    @Test("Set default fires onDefaultChanged with the install's lib dir")
    func setDefault() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        try seedInstall(tmp, "GPTK-4.0")
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let vm = GPTKManagerViewModel(importer: GPTKImporter(runner: FakeProcessRunner(), paths: paths))
        vm.refresh()

        var changed: GPTKInstall?
        vm.onDefaultChanged = { changed = $0 }
        vm.setDefault(vm.installs[0])

        #expect(vm.defaultName == "GPTK-4.0")
        #expect(vm.isDefault(vm.installs[0]))
        #expect(changed?.gptkLibDir.lastPathComponent == "x86_64-windows")
    }

    @Test("Remove deletes the install and clears a stale default")
    func remove() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        try seedInstall(tmp, "GPTK-4.0")
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let vm = GPTKManagerViewModel(importer: GPTKImporter(runner: FakeProcessRunner(), paths: paths))
        vm.refresh()
        vm.setDefault(vm.installs[0])

        await vm.remove(vm.installs[0])
        #expect(vm.installs.isEmpty)
        #expect(vm.defaultName == nil)
    }
}
