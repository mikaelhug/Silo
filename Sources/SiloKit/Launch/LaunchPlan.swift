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
        var lines = ["\(Self.launchHeaderMarker) @ \(Self.timestampFormatter.string(from: date)) ====="]
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
    /// Written at the top of every launch. Silo's logs APPEND across runs, so anything that reads a log back
    /// must slice from the LAST occurrence of this — otherwise a one-off failure is re-detected forever.
    public static let launchHeaderMarker = "===== Silo launch"

    /// Everything logged by the MOST RECENT launch, i.e. from the last header on. Returns the whole text when
    /// no header is present (a log written before this existed, or one a game wrote itself).
    public static func lastLaunchSection(of log: String) -> String {
        guard let start = log.range(of: launchHeaderMarker, options: .backwards) else { return log }
        return String(log[start.lowerBound...])
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
