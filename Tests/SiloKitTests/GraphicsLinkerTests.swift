import Foundation
import Testing
@testable import SiloKit

@Suite("GraphicsLinker")
struct GraphicsLinkerTests {
    let linker = GraphicsLinker()

    /// Make a fake source library dir with the given (empty) files.
    private func makeSource(_ tmp: TempDir, named: String, files: [String]) throws -> URL {
        let dir = try tmp.makeDir(named)
        for file in files { try tmp.write("\(named)/\(file)", "binary") }
        return dir
    }

    @Test("Symlinks GPTK libraries into system32")
    func gptkSymlink() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let gptk = try makeSource(tmp, named: "gptk", files: ["D3DMetal.dll", "dxgi.dll"])
        let prefix = try tmp.makeDir("prefix")

        try linker.link(backend: .gptk, into: prefix, gptkLibDir: gptk, dxvkDLLDir: nil, mode: .symlink)

        let system32 = PrefixLayout(prefix: prefix).system32
        for file in ["D3DMetal.dll", "dxgi.dll"] {
            let link = system32.appendingPathComponent(file)
            let isLink = try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink
            #expect(isLink == true)
            #expect(FileManager.default.fileExists(atPath: link.path))   // resolves to a real file
        }
    }

    @Test("Only graphics DLLs are linked — non-d3d/dxgi files in the source are left alone")
    func scopedToGraphicsDLLs() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        // A GPTK wine-DLL dir can hold non-graphics DLLs; those must NOT clobber the shared bottle.
        let gptk = try makeSource(tmp, named: "gptk", files: ["d3d11.dll", "kernel32.dll", "winegstreamer.dll"])
        let prefix = try tmp.makeDir("prefix")
        try linker.link(backend: .gptk, into: prefix, gptkLibDir: gptk, dxvkDLLDir: nil)

        let system32 = PrefixLayout(prefix: prefix).system32
        #expect(FileManager.default.fileExists(atPath: system32.appendingPathComponent("d3d11.dll").path))
        #expect(!FileManager.default.fileExists(atPath: system32.appendingPathComponent("kernel32.dll").path))
        #expect(!FileManager.default.fileExists(atPath: system32.appendingPathComponent("winegstreamer.dll").path))
    }

    @Test("Copies DXVK DLLs for the crossover backend")
    func crossoverCopy() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dxvk = try makeSource(tmp, named: "dxvk", files: ["d3d11.dll", "dxgi.dll"])
        let prefix = try tmp.makeDir("prefix")

        try linker.link(backend: .crossover, into: prefix, gptkLibDir: nil, dxvkDLLDir: dxvk, mode: .copy)

        let dest = PrefixLayout(prefix: prefix).system32.appendingPathComponent("d3d11.dll")
        let isLink = try dest.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink
        #expect(isLink == false)                          // a real copy, not a symlink
        #expect(FileManager.default.fileExists(atPath: dest.path))
    }

    @Test("Re-linking replaces existing entries (idempotent)")
    func reLink() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let gptk = try makeSource(tmp, named: "gptk", files: ["dxgi.dll"])
        let prefix = try tmp.makeDir("prefix")
        try linker.link(backend: .gptk, into: prefix, gptkLibDir: gptk, dxvkDLLDir: nil)
        try linker.link(backend: .gptk, into: prefix, gptkLibDir: gptk, dxvkDLLDir: nil)   // no throw
        #expect(FileManager.default.fileExists(
            atPath: PrefixLayout(prefix: prefix).system32.appendingPathComponent("dxgi.dll").path))
    }

    @Test("Throws backendNotConfigured when the source dir is nil")
    func notConfigured() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefix = try tmp.makeDir("prefix")
        #expect(throws: GraphicsLinker.LinkError.backendNotConfigured(.gptk)) {
            try linker.link(backend: .gptk, into: prefix, gptkLibDir: nil, dxvkDLLDir: nil)
        }
    }

    @Test("Throws sourceMissing when the source dir does not exist")
    func sourceMissing() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefix = try tmp.makeDir("prefix")
        let missing = tmp.url.appendingPathComponent("nope")
        #expect(throws: GraphicsLinker.LinkError.sourceMissing(missing)) {
            try linker.link(backend: .gptk, into: prefix, gptkLibDir: missing, dxvkDLLDir: nil)
        }
    }
}
