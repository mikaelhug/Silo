import Foundation
import Darwin

/// Filesystem-type checks (via `statfs`) — used to keep Wine bottles off filesystems that can't hold them.
enum Filesystem {
    /// APFS copy-on-write clone (`clonefile`) of a file/dir tree, falling back to a deep copy when the
    /// target volume can't clone (non-APFS / cross-volume). Near-free on APFS — only diverging blocks are
    /// ever written. `dst` must NOT already exist (clonefile's requirement). Throws on a failed copy.
    static func clone(from src: URL, to dst: URL, using fileManager: FileManager = .default) throws {
        let rc = src.path.withCString { s in dst.path.withCString { d in clonefile(s, d, 0) } }
        if rc != 0 { try fileManager.copyItem(at: src, to: dst) }
    }

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
