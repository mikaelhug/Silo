import Foundation

/// Tells whether the bottle's Steam client is ready for a co-resident game's `SteamAPI_Init` — replacing
/// the old fixed cold-start sleep with the actual signal.
///
/// When the Windows Steam client comes up it advertises itself in the registry under
/// `[Software\Valve\Steam\ActiveProcess]` with a non-zero `pid` (plus the client-DLL paths) — and that is
/// exactly what the Steamworks API in a game reads to connect. In a Wine prefix the HKCU hive is the text
/// file `user.reg`, so "Steam is ready" == that key carries a non-zero pid there. A kqueue watch on
/// `user.reg` lets the launch resolve the instant Steam writes it, with no polling and no fixed wait.
enum SteamReadiness {
    /// HKCU registry hive inside a Wine prefix.
    static func userReg(prefix: URL) -> URL { prefix.appendingPathComponent("user.reg") }

    /// Whether `prefix`'s Steam has registered a live `ActiveProcess` pid.
    static func isReady(prefix: URL) -> Bool {
        guard let text = try? String(contentsOf: userReg(prefix: prefix), encoding: .utf8) else { return false }
        return hasActivePid(text)
    }

    /// Pure parse: does a Wine `user.reg` carry a non-zero `"pid"` under the `ActiveProcess` section?
    /// (Section detection is lenient about backslash escaping — `[Software\\Valve\\Steam\\ActiveProcess]`.)
    static func hasActivePid(_ userReg: String) -> Bool {
        var inActiveProcess = false
        for rawLine in userReg.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {                       // a new section header
                inActiveProcess = line.contains("ActiveProcess")
                continue
            }
            if inActiveProcess, line.hasPrefix("\"pid\"=dword:") {
                let hex = line.dropFirst("\"pid\"=dword:".count)
                return (UInt64(hex, radix: 16) ?? 0) != 0
            }
        }
        return false
    }
}
