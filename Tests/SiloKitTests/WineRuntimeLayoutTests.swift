import Foundation
import Testing
@testable import SiloKit

@Suite("WineRuntimeLayout")
struct WineRuntimeLayoutTests {

    @Test("Derives the runtime FS layout from a wine binary")
    func fromWineBinary() {
        let root = URL(fileURLWithPath: "/rt/Wine-9.0")
        let layout = WineRuntimeLayout(wineBinary: root.appendingPathComponent("bin/wine64"))
        #expect(layout.root.path == "/rt/Wine-9.0")
        #expect(layout.bundledDylibDir.path == "/rt/Wine-9.0/lib/silo-bundled")
        #expect(layout.externalDir.path == "/rt/Wine-9.0/lib/external")
        #expect(layout.windowsModulesDir.path == "/rt/Wine-9.0/lib/wine/x86_64-windows")
        #expect(layout.unixModulesDir.path == "/rt/Wine-9.0/lib/wine/x86_64-unix")
        #expect(layout.wrapperExe.path == "/rt/Wine-9.0/share/silo/steamwebhelper-wrapper.exe")
    }

    @Test("init(root:) anchors directly on the runtime root")
    func fromRoot() {
        let layout = WineRuntimeLayout(root: URL(fileURLWithPath: "/rt/Wine-9.0"))
        #expect(layout.bundledDylibDir.path == "/rt/Wine-9.0/lib/silo-bundled")
    }
}
