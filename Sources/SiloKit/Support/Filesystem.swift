import Foundation

/// Filesystem-type checks (via `statfs`) — used to keep Wine bottles off filesystems that can't hold them.
enum Filesystem {
    /// The filesystem type backing `url` (`statfs`'s `f_fstypename`, lowercased: "apfs", "hfs", "exfat",
    /// "msdos", "smbfs", …), or nil if it can't be determined.
    static func type(of url: URL) -> String? {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        let name = withUnsafePointer(to: &info.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        return name.lowercased()
    }

    /// exFAT / FAT (`msdos` / `vfat`) — no POSIX symlink support, so a Wine prefix can't live there.
    /// (A bottle is full of symlinks: `dosdevices`, the user profile, etc.)
    static func isFATFamily(_ url: URL) -> Bool {
        switch type(of: url) {
        case "exfat", "msdos", "vfat": return true
        default: return false
        }
    }
}
