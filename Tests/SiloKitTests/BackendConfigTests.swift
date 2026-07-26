import Foundation
import Testing
@testable import SiloKit

@Suite("BackendConfig")
struct BackendConfigTests {

    @Test("libDir(for:) maps each backend to its own configured lib dir — no cross-wiring")
    func libDirMapping() {
        var c = BackendConfig()
        c.gptkLibDirPath = URL(fileURLWithPath: "/g")
        c.dxmtLibDirPath = URL(fileURLWithPath: "/d")
        c.dxvkLibDirPath = URL(fileURLWithPath: "/x")
        #expect(c.libDir(for: .gptk) == URL(fileURLWithPath: "/g"))
        #expect(c.libDir(for: .dxmt) == URL(fileURLWithPath: "/d"))
        #expect(c.libDir(for: .dxvk) == URL(fileURLWithPath: "/x"))
    }

    @Test("The DXVK fields round-trip through Codable")
    func dxvkFieldsRoundTrip() throws {
        var c = BackendConfig()
        c.dxvkLibDirPath = URL(fileURLWithPath: "/rt/dxvk/lib/wine/x86_64-windows")
        c.dxvkRuntimeName = "dxvk-v2.4-cx26.2.0"
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(BackendConfig.self, from: data)
        #expect(back.dxvkLibDirPath == c.dxvkLibDirPath)
        #expect(back.dxvkRuntimeName == "dxvk-v2.4-cx26.2.0")
    }

    @Test("A pre-DXVK config.json (no dxvk keys) still decodes — tolerant decode, DXVK just unset")
    func tolerantDecodeOfLegacyConfig() throws {
        // A document written before the DXVK fields existed: only the GPTK/wine keys are present.
        let legacy = #"{"wineBinaryPath":"file:///w/bin/wine64","gptkRuntimeName":"GPTK","retinaMode":true}"#
        let c = try JSONDecoder().decode(BackendConfig.self, from: Data(legacy.utf8))
        #expect(c.gptkRuntimeName == "GPTK")
        #expect(c.retinaMode)
        #expect(c.dxvkLibDirPath == nil)     // absent → unset, not a decode failure that drops the doc
        #expect(c.libDir(for: .dxvk) == nil)
    }

    @Test("dxvkSupports32Bit is true only when the runtime ships an i386 d3d11.dll sibling")
    func dxvkSupports32Bit() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        var c = BackendConfig()
        #expect(!c.dxvkSupports32Bit)                                   // unset → false

        let x64 = try tmp.makeDir("dxvk/lib/wine/x86_64-windows")
        try tmp.write("dxvk/lib/wine/x86_64-windows/d3d11.dll", "PE")
        c.dxvkLibDirPath = x64
        #expect(!c.dxvkSupports32Bit)                                   // no i386 sibling yet → false

        try tmp.makeDir("dxvk/lib/wine/i386-windows")
        try tmp.write("dxvk/lib/wine/i386-windows/d3d11.dll", "PE32")   // the 32-bit DX9 path
        #expect(c.dxvkSupports32Bit)
    }
}
