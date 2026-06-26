import Foundation

/// Steam's `AppState.StateFlags` bitfield from an `appmanifest_*.acf`.
public struct StateFlags: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let uninstalled    = StateFlags(rawValue: 1)
    public static let updateRequired = StateFlags(rawValue: 2)
    public static let fullyInstalled = StateFlags(rawValue: 4)
    public static let encrypted      = StateFlags(rawValue: 8)
    public static let locked         = StateFlags(rawValue: 16)
    public static let filesMissing   = StateFlags(rawValue: 32)
    public static let appRunning     = StateFlags(rawValue: 64)
    public static let filesCorrupt   = StateFlags(rawValue: 128)
    public static let updateRunning  = StateFlags(rawValue: 256)
    public static let updateStarted  = StateFlags(rawValue: 512)
    public static let uninstalling   = StateFlags(rawValue: 1024)
    public static let downloading    = StateFlags(rawValue: 1_048_576)

    public var isFullyInstalled: Bool { contains(.fullyInstalled) }
    public var needsUpdate: Bool { contains(.updateRequired) }
    public var isDownloading: Bool {
        contains(.downloading) || contains(.updateRunning) || contains(.updateStarted)
    }
}
