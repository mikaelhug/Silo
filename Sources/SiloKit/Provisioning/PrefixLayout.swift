import Foundation

/// Path math for the standard directories inside a Wine prefix.
public struct PrefixLayout: Sendable {
    public let prefix: URL
    public init(prefix: URL) { self.prefix = prefix }

    public var driveC: URL { prefix.appendingPathComponent("drive_c", isDirectory: true) }
    public var windows: URL { driveC.appendingPathComponent("windows", isDirectory: true) }
    public var system32: URL { windows.appendingPathComponent("system32", isDirectory: true) }
    public var syswow64: URL { windows.appendingPathComponent("syswow64", isDirectory: true) }
    public var systemReg: URL { prefix.appendingPathComponent("system.reg") }
    public var dosDevices: URL { prefix.appendingPathComponent("dosdevices", isDirectory: true) }
}
