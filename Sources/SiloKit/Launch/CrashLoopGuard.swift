import Foundation

/// Safety net behind every Steam/game launch: watches for a wine crash-loop — a `winedbg --auto`
/// storm caused by a process (e.g. Steam's CEF) crashing and being relaunched over and over — and
/// force-kills the bottle (`wineserver -k`) before it floods the Mac with hundreds of debugger
/// processes. Runs as a detached background task; cheap (polls a process count) and self-terminating.
public struct CrashLoopGuard: Sendable {
    private let runner: ProcessRunning
    public init(runner: ProcessRunning) { self.runner = runner }

    /// Poll `winedbg --auto` count every `interval`; if it reaches `threshold`, kill `bottle` and stop.
    /// Gives up after `maxChecks` polls (the launch is assumed healthy by then).
    public func monitor(
        wine: URL,
        bottle: URL,
        threshold: Int = 30,
        interval: Duration = .seconds(3),
        maxChecks: Int = 40
    ) async {
        for _ in 0..<maxChecks {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return }
            let storm = await runner.processCount(matching: "winedbg --auto")
            guard storm >= threshold else { continue }
            let wineserver = wine.deletingLastPathComponent().appendingPathComponent("wineserver")
            _ = try? await runner.run(
                executable: wineserver, arguments: ["-k"],
                environment: ["WINEPREFIX": bottle.path], currentDirectory: nil)
            return
        }
    }
}
