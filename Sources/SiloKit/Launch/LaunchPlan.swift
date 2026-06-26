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
}
