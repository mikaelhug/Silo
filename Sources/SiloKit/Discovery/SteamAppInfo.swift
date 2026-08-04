import Foundation

/// Reads Steam's own **launch configuration** for an app out of `appcache/appinfo.vdf` — the executable to
/// run and the arguments to pass, exactly as the Steam client would.
///
/// This is what makes Source-engine games work. `hl2.exe` is a shared launcher that needs `-game <moddir>`
/// to know which mod to load; without it Double Action: Boogaloo silently runs base Half-Life 2 content and
/// *appears* to launch, while Transmissions: Element 120 dies on "gameinfo.txt doesn't exist in subdirectory
/// 'hl2'". Steam has always had the answer (`-game dab`, `-game te120`); Silo just never read it and instead
/// guessed the executable from file sizes.
///
/// The file is binary VDF. Two container revisions matter: **v41** (`0x07564429`) keeps every key in one
/// string table at the end and stores 4-byte indices into it, while **v40 and older** write key names inline.
/// Both are handled — a Steam client update that flips the format must not silently drop launch options.
public enum SteamAppInfo: Sendable {

    /// One `config/launch/<n>` entry: what to run, with what, on which OS.
    public struct LaunchEntry: Sendable, Equatable {
        public let executable: String
        public let arguments: [String]
        public let osList: String?
        public let type: String?
        /// Beta-only entries must never be chosen for a normal launch.
        public let betaKey: String?
    }

    /// The launch entry Silo should use for a Windows game, or nil if the file has nothing usable.
    ///
    /// Chooses the first entry that targets Windows (or declares no OS at all — common for single-platform
    /// apps like Alien Swarm), is not beta-gated, and is not an editor/tool (`type: "none"`, which is how
    /// Double Action tags `bin/hammer.exe`).
    public static func windowsLaunch(steamRoot: URL, appID: Int,
                                     fileManager: FileManager = .default) -> LaunchEntry? {
        let url = steamRoot.appendingPathComponent("appcache/appinfo.vdf")
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return windowsLaunch(appInfo: data, appID: appID)
    }

    /// Testable core: same selection, over bytes already in hand.
    public static func windowsLaunch(appInfo data: Data, appID: Int) -> LaunchEntry? {
        entries(appInfo: data, appID: appID).first { entry in
            guard entry.betaKey?.isEmpty != false else { return false }
            guard entry.type?.lowercased() != "none" else { return false }
            guard let os = entry.osList?.lowercased(), !os.isEmpty else { return true }   // unset ⇒ usable
            return os.split(separator: ",").contains("windows")
        }
    }

    /// Every launch entry for `appID`, in Steam's own order (its numeric keys are ordered by the client).
    static func entries(appInfo data: Data, appID: Int) -> [LaunchEntry] {
        guard data.count > 16 else { return [] }
        let magic = data.u32(0)
        var stringTable: [String] = []
        var cursor: Int

        switch magic {
        case 0x07564429:                                  // v41 — keys live in a table at `stringTableOffset`
            let offset = Int(data.u64(8))
            guard offset > 0, offset + 4 <= data.count else { return [] }
            var p = offset + 4
            for _ in 0..<Int(data.u32(offset)) {
                guard let end = data.indexOfZero(from: p) else { return [] }
                stringTable.append(String(decoding: data[p..<end], as: UTF8.self))
                p = end + 1
            }
            cursor = 16
        case 0x07564428, 0x07564427:                      // v40 / v39 — inline keys
            cursor = 8
        default:
            return []
        }

        while cursor + 8 <= data.count {
            let id = Int(data.u32(cursor))
            if id == 0 { break }
            let size = Int(data.u32(cursor + 4))
            let bodyStart = cursor + 8
            guard size >= 0, bodyStart + size <= data.count else { return [] }
            if id == appID {
                // A fixed-size record (state, timestamps, token, hashes, change number) precedes the KV blob.
                // Its length varies by revision, so rather than hard-code it, scan forward for the first
                // offset that parses as a map — wrong guesses fail fast and cheaply.
                let body = data[bodyStart..<(bodyStart + size)]
                for skip in [60, 64, 56, 52, 48, 44, 40] where skip < size {
                    var p = body.startIndex + skip
                    if let root = parseMap(body, &p, stringTable), !root.isEmpty {
                        return launchEntries(from: root)
                    }
                }
                return []
            }
            cursor = bodyStart + size
        }
        return []
    }

    // MARK: - Binary VDF

    /// A parsed node: either a nested map or a leaf value.
    private indirect enum Node { case map([String: Node]), string(String), int(Int32) }

    /// Parse one binary-VDF map. Returns nil the moment anything doesn't fit — the caller uses that to
    /// reject a wrong start offset, so this must never trap on unexpected bytes.
    private static func parseMap(_ d: Data, _ p: inout Int, _ table: [String]) -> [String: Node]? {
        var out: [String: Node] = [:]
        var guardCount = 0
        while p < d.endIndex {
            guardCount += 1
            if guardCount > 4096 { return nil }
            let type = d[p]; p += 1
            if type == 0x08 { return out }                       // end of map
            let key: String
            if table.isEmpty {
                guard let end = d.indexOfZero(from: p) else { return nil }
                key = String(decoding: d[p..<end], as: UTF8.self); p = end + 1
            } else {
                guard p + 4 <= d.endIndex else { return nil }
                let idx = Int(d.u32(p - d.startIndex)); p += 4
                guard idx < table.count else { return nil }
                key = table[idx]
            }
            switch type {
            case 0x00:
                guard let sub = parseMap(d, &p, table) else { return nil }
                out[key] = .map(sub)
            case 0x01:
                guard let end = d.indexOfZero(from: p) else { return nil }
                out[key] = .string(String(decoding: d[p..<end], as: UTF8.self)); p = end + 1
            case 0x02:
                guard p + 4 <= d.endIndex else { return nil }
                out[key] = .int(Int32(bitPattern: d.u32(p - d.startIndex))); p += 4
            default:
                return nil                                        // unknown type ⇒ wrong offset
            }
        }
        return out
    }

    private static func launchEntries(from root: [String: Node]) -> [LaunchEntry] {
        var node = root
        if case .map(let inner)? = node["appinfo"] { node = inner }
        guard case .map(let config)? = node["config"], case .map(let launch)? = config["launch"] else {
            return []
        }
        return launch.keys.sorted { (Int($0) ?? .max) < (Int($1) ?? .max) }.compactMap { key in
            guard case .map(let entry)? = launch[key],
                  case .string(let exe)? = entry["executable"], !exe.isEmpty else { return nil }
            var os: String?, beta: String?
            if case .map(let cfg)? = entry["config"] {
                if case .string(let list)? = cfg["oslist"] { os = list }
                if case .string(let key)? = cfg["betakey"] { beta = key }
            }
            var args: [String] = []
            if case .string(let raw)? = entry["arguments"] { args = splitArguments(raw) }
            var type: String?
            if case .string(let t)? = entry["type"] { type = t }
            return LaunchEntry(executable: exe, arguments: args, osList: os, type: type, betaKey: beta)
        }
    }

    /// Split Steam's argument string on whitespace, honouring double quotes (a path with spaces is quoted).
    static func splitArguments(_ raw: String) -> [String] {
        var out: [String] = [], current = "", quoted = false
        for ch in raw {
            if ch == "\"" { quoted.toggle() }
            else if ch.isWhitespace && !quoted {
                if !current.isEmpty { out.append(current); current = "" }
            } else { current.append(ch) }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

// MARK: - Bounds-checked reads

private extension Data {
    func u32(_ i: Int) -> UInt32 {
        let b = startIndex + i
        return UInt32(self[b]) | UInt32(self[b + 1]) << 8 | UInt32(self[b + 2]) << 16 | UInt32(self[b + 3]) << 24
    }
    func u64(_ i: Int) -> UInt64 { UInt64(u32(i)) | UInt64(u32(i + 4)) << 32 }
    /// Absolute index of the next NUL at or after absolute index `p`, or nil.
    func indexOfZero(from p: Int) -> Int? {
        var i = p
        while i < endIndex { if self[i] == 0 { return i }; i += 1 }
        return nil
    }
}
