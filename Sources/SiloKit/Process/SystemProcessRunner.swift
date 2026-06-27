import Foundation
import Darwin

/// `Foundation.Process`-backed `ProcessRunning`.
///
/// `run` redirects child output to temp files (instead of pipes) to avoid pipe-buffer deadlock and
/// keep everything local to one background closure (Swift 6 concurrency-clean). The provided
/// environment is merged onto the current process environment so `PATH` etc. are preserved while
/// callers override `WINEPREFIX`, `WINEESYNC`, …
public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try Self.runSync(
                        executable: executable, arguments: arguments,
                        environment: environment, currentDirectory: currentDirectory
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @discardableResult
    public func spawnDetached(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?,
        logURL: URL
    ) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let pid = try Self.spawnSync(
                        executable: executable, arguments: arguments,
                        environment: environment, currentDirectory: currentDirectory, logURL: logURL
                    )
                    continuation.resume(returning: pid)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func isRunning(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        // kill(pid, 0): 0 → alive & signalable; EPERM → alive but not ours; ESRCH → gone.
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    public func terminate(pid: Int32) {
        guard pid > 0 else { return }
        kill(pid, SIGTERM)
    }

    public func processCount(matching pattern: String) async -> Int {
        // `pgrep -fc <pattern>`: -f matches the full command line, -c prints the count.
        let result = try? await run(
            executable: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-fc", pattern], environment: [:], currentDirectory: nil)
        let text = result?.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        return Int(text) ?? 0
    }

    public func firstPID(matching pattern: String) async -> Int32? {
        let result = try? await run(
            executable: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-f", pattern], environment: [:], currentDirectory: nil)
        return result?.stdoutString
            .split(whereSeparator: \.isNewline).first
            .flatMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    public func observeExit(pid: Int32, onExit: @escaping @Sendable () -> Void) -> any ProcessObservation {
        guard pid > 0 else { return NoopObservation() }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler(handler: onExit)
        source.resume()
        return DispatchObservation(source)
    }

    public func observeWrites(at url: URL, onWrite: @escaping @Sendable () -> Void) -> any ProcessObservation {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return NoopObservation() }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend], queue: .global())
        source.setEventHandler(handler: onWrite)
        source.setCancelHandler { close(fd) }
        source.resume()
        return DispatchObservation(source)
    }

    // MARK: - Synchronous workers (run on a background queue)

    private static func mergedEnvironment(_ overrides: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for (key, value) in overrides { env[key] = value }
        return env
    }

    private static func runSync(
        executable: URL, arguments: [String],
        environment: [String: String], currentDirectory: URL?
    ) throws -> ProcessResult {
        let fileManager = FileManager.default
        let tmp = fileManager.temporaryDirectory
        let outURL = tmp.appendingPathComponent("silo-out-\(UUID().uuidString)")
        let errURL = tmp.appendingPathComponent("silo-err-\(UUID().uuidString)")
        fileManager.createFile(atPath: outURL.path, contents: nil)
        fileManager.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? fileManager.removeItem(at: outURL)
            try? fileManager.removeItem(at: errURL)
        }

        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        defer { try? outHandle.close(); try? errHandle.close() }   // also closes if process.run() throws

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = mergedEnvironment(environment)
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardOutput = outHandle
        process.standardError = errHandle

        try process.run()
        process.waitUntilExit()

        let outData = (try? Data(contentsOf: outURL)) ?? Data()
        let errData = (try? Data(contentsOf: errURL)) ?? Data()
        return ProcessResult(exitCode: process.terminationStatus, standardOutput: outData, standardError: errData)
    }

    private static func spawnSync(
        executable: URL, arguments: [String],
        environment: [String: String], currentDirectory: URL?, logURL: URL
    ) throws -> Int32 {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try FileHandle(forWritingTo: logURL)
        defer { try? logHandle.close() }   // also closes if process.run() throws
        logHandle.seekToEndOfFile()

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = mergedEnvironment(environment)
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardOutput = logHandle
        process.standardError = logHandle

        // Detached: we do not waitUntilExit. On macOS a child outlives its parent unless explicitly
        // signalled, so the game keeps running after Silo quits. The child dup's the log fd at spawn,
        // so closing our handle afterward is safe.
        try process.run()
        return process.processIdentifier
    }
}

/// Owns a `DispatchSource` (process-exit or file-write) and tears it down on `cancel()`/deinit.
/// Held on the actor that created it; the wrapped source is internally thread-safe.
private final class DispatchObservation: ProcessObservation {
    private let source: any DispatchSourceProtocol
    init(_ source: any DispatchSourceProtocol) { self.source = source }
    func cancel() { source.cancel() }   // also runs the cancel handler (closes the file fd)
    deinit { source.cancel() }
}
