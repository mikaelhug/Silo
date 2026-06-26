import Foundation

/// Top-level namespace + build metadata for the Silo app.
public enum Silo {
    /// Marketing version. Kept in sync with `Info.plist` `CFBundleShortVersionString` by the build script.
    public static let version = "0.1.0"

    /// Stable bundle identifier (TCC prompts are keyed to this).
    public static let bundleID = "com.mikael.silo"

    /// User-facing product name.
    public static let appName = "Silo"

    /// GitHub repo (`owner/name`) the in-app updater checks for new app releases.
    public static let updateRepo = "mikaelhug/Silo"

    /// Default third-party repo (`owner/name`) for downloadable Wine/GPTK runtimes.
    /// Overridable in Settings. NOTE: confirm the exact repo/release to pin (see STATUS "BLOCKED").
    public static let defaultRuntimeRepo = "Kegworks-App/Kegworks"
}
