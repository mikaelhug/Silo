import Foundation

/// One launchable a Windows installer registered in a bottle (its Start-Menu / Desktop `.lnk`), resolved to
/// host paths Silo can launch. This is what a post-installer picker offers so a manual game inherits the
/// installer's own correct launch — target + args + working dir — instead of the user guessing an `.exe`.
public struct DiscoveredShortcut: Equatable, Sendable, Identifiable {
    /// The shortcut's friendly label (e.g. "GravityMark GPU Benchmark"), falling back to the exe's name.
    public var name: String
    /// Host path to the target executable, inside the bottle's `drive_c`.
    public var executable: URL
    /// Arguments the shortcut passes (whitespace-split, matching `ManualGame.customArgs` semantics).
    public var arguments: [String]
    /// The shortcut's "start in" directory as a host path, or `nil` to default to the exe's folder.
    public var workingDirectory: URL?
    /// Host path the icon is drawn from (a `.ico`/`.exe`), best-effort; `nil` if unmapped.
    public var iconLocation: URL?

    public var id: String { executable.path + "\u{1}" + arguments.joined(separator: " ") }
}

/// Discovers the shortcuts an installer left in a bottle. Pure format/FS logic (no process, no runtime), so
/// it unit-tests against a fake prefix tree.
public enum BottleShortcuts {
    /// Every usable launchable shortcut under `prefix` (a bottle root whose `drive_c` holds the install),
    /// deduplicated by target+args, uninstaller/noise entries dropped. Empty when nothing resolvable is found.
    public static func discover(inBottle prefix: URL, fileManager: FileManager = .default) -> [DiscoveredShortcut] {
        var out: [DiscoveredShortcut] = []
        var seen = Set<String>()
        for dir in shortcutSearchDirs(prefix: prefix, fileManager: fileManager) {
            guard let e = fileManager.enumerator(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in e where url.pathExtension.lowercased() == "lnk" {
                guard let data = try? Data(contentsOf: url),
                      let link = ShellLink.parse(data),
                      let shortcut = resolve(link, prefix: prefix, fileManager: fileManager),
                      seen.insert(shortcut.id).inserted else { continue }
                out.append(shortcut)
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Turn a parsed link into a launchable shortcut, or `nil` if it's an uninstaller, unresolvable, or its
    /// target isn't an existing `.exe` in the bottle.
    static func resolve(
        _ link: ShellLink, prefix: URL, fileManager: FileManager = .default
    ) -> DiscoveredShortcut? {
        guard let winTarget = link.targetPath,
              let exe = hostURL(forWindowsPath: winTarget, prefix: prefix),
              !isUninstaller(name: link.name, target: exe) else { return nil }
        guard exe.pathExtension.lowercased() == "exe",
              fileManager.fileExists(atPath: exe.path) else { return nil }

        let args = (link.arguments ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        let workDir = link.workingDirectory.flatMap { hostURL(forWindowsPath: $0, prefix: prefix) }
        let icon = link.iconLocation.flatMap { hostURL(forWindowsPath: $0, prefix: prefix) }
        let name = link.name?.trimmingCharacters(in: .whitespaces)
        return DiscoveredShortcut(
            name: (name?.isEmpty == false ? name! : exe.deletingPathExtension().lastPathComponent),
            executable: exe, arguments: args, workingDirectory: workDir, iconLocation: icon)
    }

    /// An installer's uninstall entry (an "Uninstall …" label, `msiexec`, or Inno `unins*.exe`) — never a
    /// game to add.
    static func isUninstaller(name: String?, target: URL) -> Bool {
        let base = target.deletingPathExtension().lastPathComponent.lowercased()
        if base == "msiexec" || base.hasPrefix("unins") { return true }
        if let name, name.range(of: "uninstall", options: .caseInsensitive) != nil { return true }
        return false
    }

    /// Map a Windows path (`C:\Program Files\…`) to its host path under `prefix/drive_c`. Only the `C:` drive
    /// (where installers land) is mapped; a network/other-letter path returns `nil`.
    static func hostURL(forWindowsPath win: String, prefix: URL) -> URL? {
        let chars = Array(win)
        guard chars.count >= 2, chars[1] == ":", chars[0] == "C" || chars[0] == "c" else { return nil }
        let rest = String(chars[2...]).replacingOccurrences(of: "\\", with: "/")
        let trimmed = rest.hasPrefix("/") ? String(rest.dropFirst()) : rest
        return prefix.appendingPathComponent("drive_c").appendingPathComponent(trimmed)
    }

    /// The standard Windows shortcut locations inside a bottle: every user's + the all-users Start Menu and
    /// Desktop. Only those that exist are returned.
    private static func shortcutSearchDirs(prefix: URL, fileManager: FileManager) -> [URL] {
        let driveC = prefix.appendingPathComponent("drive_c")
        let usersDir = driveC.appendingPathComponent("users")
        var users = (try? fileManager.contentsOfDirectory(
            at: usersDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        // ProgramData holds the all-users Start Menu; treat it like a synthetic "user" root for the joins.
        users.append(driveC.appendingPathComponent("ProgramData"))

        let subpaths = [
            "AppData/Roaming/Microsoft/Windows/Start Menu/Programs",
            "Microsoft/Windows/Start Menu/Programs",   // ProgramData layout
            "Desktop",
        ]
        var dirs: [URL] = []
        for root in users {
            for sub in subpaths {
                let dir = root.appendingPathComponent(sub)
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
                    dirs.append(dir)
                }
            }
        }
        return dirs
    }
}
