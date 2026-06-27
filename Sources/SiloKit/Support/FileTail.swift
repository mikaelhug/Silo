import Foundation

extension URL {
    /// Read the last `maxBytes` of this file as UTF-8 (so a huge log doesn't blow memory); "" if missing.
    /// `nonisolated`-safe — callable off any actor (e.g. from a file-watch handler).
    func tailString(maxBytes: Int = 64 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: self) else { return "" }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }
}
