import Foundation
import Testing
@testable import SiloKit

@Suite("DllOverrideList (WINEDLLOVERRIDES parse / merge / render)")
struct DllOverrideListTests {
    @Test("Every backend's override set round-trips to exactly the string it was written as")
    func backendSetsRoundTrip() {
        for backend in GraphicsBackend.allCases {
            #expect(DllOverrideList(parsing: backend.dllOverrides).rendered == backend.dllOverrides)
        }
        #expect(DllOverrideList(parsing: Silo.steamClientDllOverrides).rendered == Silo.steamClientDllOverrides)
    }

    @Test("Parsing splits module lists per module and keeps each mode verbatim, incl. disabled and n,b")
    func parsing() {
        let list = DllOverrideList(parsing: "a,b=n;c=;d=n,b; e = b ")
        #expect(list.entries == [
            .init(module: "a", mode: "n"), .init(module: "b", mode: "n"),
            .init(module: "c", mode: ""), .init(module: "d", mode: "n,b"),
            .init(module: "e", mode: "b"),
        ])
    }

    @Test("Malformed input is tolerated: nil, empty, blank segments and segments without '=' are skipped",
          arguments: [nil, "", ";;", "justaname", "=n", " ; x=b ;"])
    func tolerant(_ input: String?) {
        let list = DllOverrideList(parsing: input)
        #expect(list.entries.allSatisfy { !$0.module.isEmpty })
        #expect(list.entries.count == (input == " ; x=b ;" ? 1 : 0))
    }

    @Test("Module identity ignores case, wine's `*` prefix and a `.dll` suffix — but not `.exe`")
    func keys() {
        #expect(DllOverrideList.Entry(module: "DXGI", mode: "n").key == "dxgi")
        #expect(DllOverrideList.Entry(module: "*dxgi", mode: "n").key == "dxgi")
        #expect(DllOverrideList.Entry(module: "dxgi.dll", mode: "n").key == "dxgi")
        #expect(DllOverrideList.Entry(module: "winemenubuilder.exe", mode: "d").key == "winemenubuilder.exe")
    }

    @Test("merged: the overriding list wins per module; untouched base modules survive, in order",
          arguments: [
            // (base, overriding, expected)
            ("a,b,c=b", "", "a,b,c=b"),
            ("", "x=n", "x=n"),
            ("a,b,c=b", "b=n", "a,c=b;b=n"),
            ("a,b,c=b", "B.DLL=n", "a,c=b;B.DLL=n"),
            ("a,*b,c=b", "b=", "a,c=b;b="),
            ("a,b=b;c=", "c=n,b;z=d", "a,b=b;c=n,b;z=d"),
            ("a=b", "a=n;a=b", "a=n;a=b"),          // a duplicate inside the user's own list keeps its order
          ])
    func merged(_ base: String, _ overriding: String, _ expected: String) {
        let result = DllOverrideList.merged(
            base: DllOverrideList(parsing: base), overriding: DllOverrideList(parsing: overriding))
        #expect(result.rendered == expected)
    }

    @Test("wildcarding rewrites only the named modules to `*module`, once")
    func wildcarding() {
        let list = DllOverrideList(parsing: "d3d9,dxgi,*d3d11=b;nvngx=")
            .wildcarding(["dxgi", "d3d11", "nvngx"])
        #expect(list.rendered == "d3d9,*dxgi,*d3d11=b;*nvngx=")
    }
}
