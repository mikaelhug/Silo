import Foundation

/// A fully-resolved, side-effect-free description of how to launch a game. Produced by the pure
/// `LaunchOrchestrator.makePlan` and consumed by `spawnDetached`.
public struct LaunchPlan: Sendable, Equatable {
    public let executable: URL          // the wine binary
    public let arguments: [String]      // [gameExe.path] + customArgs
    public let environment: [String: String]
    public let currentDirectory: URL    // the game's install directory
    public let logURL: URL

    public init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL,
        logURL: URL
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.logURL = logURL
    }

    /// A human-readable context block written at the very top of each launch log: the resolved wine
    /// binary, arguments, working directory, and the full Silo-set environment (sorted). Makes a
    /// black-window / "failed to initialize graphics" report self-explanatory — you see exactly what was
    /// launched and with which GPTK/wine env, without re-deriving it. Pure (timestamp injected).
    public func logHeader(at date: Date) -> String {
        var lines = ["===== Silo launch @ \(Self.timestampFormatter.string(from: date)) ====="]
        lines.append("exe   : \(executable.path)")
        lines.append("args  : \(arguments.joined(separator: " "))")
        lines.append("cwd   : \(currentDirectory.path)")
        lines.append("env   :")
        for key in environment.keys.sorted() {
            lines.append("    \(key)=\(environment[key] ?? "")")
        }
        lines.append("===== begin process output =====\n")
        return lines.joined(separator: "\n")
    }

    /// Stable, locale-independent timestamp for the log header.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
