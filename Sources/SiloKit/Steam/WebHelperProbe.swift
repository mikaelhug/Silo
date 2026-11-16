import Foundation

/// Reads what a CEF dir's `steamwebhelper.exe` files actually ARE, from their bytes — never from which file
/// names happen to exist next to them (issue #10).
///
/// **Why bytes, not names.** `installWebHelperWrapper` used to infer "`steamwebhelper.exe` is a stale Silo
/// wrapper" from "`steamwebhelper_orig.exe` already exists". A Steam client update breaks that: it rewrites
/// `steamwebhelper.exe` with the NEW genuine binary next to the OLD preserved `_orig`, so Silo deleted the
/// fresh webhelper and kept the old one — which CEF then refuses to run against the updated `libcef.dll`
/// (observed 2026-11-16: client 1788652215 → 1794536281; Steam logs "Failed creating offscreen shared JS
/// context", no webhelper ever starts, and `-noverifyfiles` means Steam never repairs it).
enum WebHelperProbe {
    /// Silo's wrapper execs `steamwebhelper_orig.exe`, so every wrapper version carries that name as a
    /// UTF-16LE literal (`kRealExe` in `Scripts/steamwebhelper-wrapper.c`); Steam's genuine webhelper never
    /// references it. Verified on both the wrapper and the genuine binaries.
    static let wrapperMarker = Data("steamwebhelper_orig.exe".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })

    /// Whether the file at `url` is a Silo wrapper (any version) rather than Steam's genuine webhelper — nil
    /// when it can't be read. Callers must treat nil as "unknown, touch nothing": guessing "genuine" would
    /// move a wrapper over the preserved `_orig` and lose the real binary.
    static func isWrapper(at url: URL) -> Bool? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return data.range(of: wrapperMarker) != nil
    }

    /// The CEF API hashes a webhelper was built against: the 40-hex ASCII tokens it embeds. A webhelper and
    /// the `libcef.dll` beside it match iff the library carries one of them — the same check CEF itself
    /// makes at startup (verified: a consistent pair shares it, the stale pair did not).
    static func apiHashes(in data: Data) -> Set<Data> {
        var hashes: Set<Data> = []
        var start: Int?
        func isHex(_ b: UInt8) -> Bool { (0x30...0x39).contains(b) || (0x61...0x66).contains(b) }
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for i in 0...bytes.count {
                let b: UInt8 = i < bytes.count ? bytes[i] : 0
                if i < bytes.count, isHex(b) {
                    if start == nil { start = i }
                    continue
                }
                // A token must be exactly 40 hex chars, delimited by non-hex bytes on both sides.
                if let s = start, i - s == 40 { hashes.insert(Data(bytes[s..<i])) }
                start = nil
            }
        }
        return hashes
    }

    /// Whether the genuine webhelper at `helper` was built for a DIFFERENT CEF than the `libcef.dll` at
    /// `libcef`. Fails CLOSED to "not stale": a missing file, or a webhelper with no recognisable hash (a
    /// future format), is never reported — a false positive would send every launch through a repair.
    static func isStale(helper: URL, libcef: URL) -> Bool {
        guard let helperData = try? Data(contentsOf: helper, options: .alwaysMapped),
              let libData = try? Data(contentsOf: libcef, options: .alwaysMapped) else { return false }
        let hashes = apiHashes(in: helperData)
        guard !hashes.isEmpty else { return false }
        return !hashes.contains { libData.range(of: $0) != nil }
    }
}
