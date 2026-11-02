import Foundation

/// A parsed `WINEDLLOVERRIDES` value, one entry per module — the pure model `makePlan` uses to combine the
/// backend's override set with the user's own (`EnvFlags.extra["WINEDLLOVERRIDES"]`).
///
/// **Why per-module and not string concatenation.** When wine sees a module twice in `WINEDLLOVERRIDES` the
/// LATER entry wins (`dxgi=n;dxgi=b` loads the builtin). `makePlan` used to emit `"<user>;<backend>"`, so the
/// backend's set always silently beat a user override for the same module — the opposite of what
/// `EnvFlags.extra` documents (issue #9). Merging per module makes the rule explicit and order-independent:
/// a module the user names is **dropped** from the backend set, so the user's entry is the only one left.
///
/// Wine's syntax (from `ntdll`'s own help text): `entry;entry;…`, each `module[,module…]=mode`, where `mode`
/// is `n`/`b` (or `native`/`builtin`), a comma pair like `n,b`, or empty for *disabled*. A module may carry a
/// leading `*` — wine's "basename, at any path" form, which it looks up AFTER the plain name (see
/// `ProcessRouting` for why Silo uses that). Module names are compared case-insensitively, ignoring the `*`
/// and a trailing `.dll`, exactly as wine does.
public struct DllOverrideList: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        /// The module as written (may carry a `*` prefix and/or a `.exe`/`.dll` suffix).
        public var module: String
        /// The load-order mode as written (`b`, `n`, `n,b`, `native`, `""` = disabled…).
        public var mode: String

        public init(module: String, mode: String) {
            self.module = module
            self.mode = mode
        }

        /// Identity for conflict detection: lowercased, without wine's `*` prefix or a `.dll` suffix — so
        /// `DXGI`, `dxgi.dll` and `*dxgi` all name the same module.
        public var key: String { DllOverrideList.key(for: module) }
    }

    public var entries: [Entry]

    public init(_ entries: [Entry] = []) { self.entries = entries }

    /// Parse a `WINEDLLOVERRIDES` string. Tolerant: blank segments, stray whitespace and a segment without
    /// `=` are skipped (wine ignores those too), so a malformed user value can never break a launch.
    public init(parsing value: String?) {
        var parsed: [Entry] = []
        for segment in (value ?? "").split(separator: ";", omittingEmptySubsequences: true) {
            guard let eq = segment.firstIndex(of: "=") else { continue }
            let mode = segment[segment.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            for module in segment[..<eq].split(separator: ",") {
                let name = module.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { parsed.append(Entry(module: name, mode: mode)) }
            }
        }
        entries = parsed
    }

    static func key(for module: String) -> String {
        var k = module.lowercased()
        if k.hasPrefix("*") { k.removeFirst() }
        if k.hasSuffix(".dll") { k.removeLast(4) }
        return k
    }

    /// The modules this list names, by `Entry.key`.
    public var keys: Set<String> { Set(entries.map(\.key)) }

    /// `base` with every module that `overriding` names removed, followed by `overriding` — so on any module
    /// both name, `overriding`'s entry is the only one present (and, belt and braces, also the later one).
    public static func merged(base: DllOverrideList, overriding: DllOverrideList) -> DllOverrideList {
        let claimed = overriding.keys
        return DllOverrideList(base.entries.filter { !claimed.contains($0.key) } + overriding.entries)
    }

    /// This list with the named modules rewritten to wine's `*module` form (others untouched). `*module` is
    /// looked up only AFTER the plain name, so a per-executable `AppDefaults` entry for that module beats it
    /// while it still governs every other process — see `ProcessRouting`.
    public func wildcarding(_ modules: Set<String>) -> DllOverrideList {
        DllOverrideList(entries.map { entry in
            guard modules.contains(entry.key), !entry.module.hasPrefix("*") else { return entry }
            return Entry(module: "*" + entry.module, mode: entry.mode)
        })
    }

    /// Render back to `WINEDLLOVERRIDES` syntax, grouping only CONSECUTIVE modules that share a mode — so
    /// entry order (which decides a duplicate inside one list: wine takes the later one) is preserved exactly,
    /// and a backend set round-trips to precisely the string it was written as.
    public var rendered: String {
        var groups: [(modules: [String], mode: String)] = []
        for entry in entries {
            if let last = groups.indices.last, groups[last].mode == entry.mode {
                groups[last].modules.append(entry.module)
            } else {
                groups.append(([entry.module], entry.mode))
            }
        }
        return groups.map { "\($0.modules.joined(separator: ","))=\($0.mode)" }.joined(separator: ";")
    }
}
