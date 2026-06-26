import Foundation

/// The outcome of a finished subprocess.
public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: Data

    public init(exitCode: Int32, standardOutput: Data = Data(), standardError: Data = Data()) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var succeeded: Bool { exitCode == 0 }
    public var stdoutString: String { String(decoding: standardOutput, as: UTF8.self) }
    public var stderrString: String { String(decoding: standardError, as: UTF8.self) }
}
