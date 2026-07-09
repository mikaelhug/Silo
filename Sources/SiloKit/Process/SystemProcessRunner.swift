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

    /// `Foundation.Process` raises an Objective-C exception (not a catchable Swift error) when handed a
    /// non-file executable URL. Validate every filesystem role before touching `Process` so a malformed or
    /// hand-edited config becomes an ordinary surfaced error instead of terminating Silo.
    public enum RunnerError: Error, Sendable, Equatable {
        case nonFileExecutableURL(String)
        case nonFileCurrentDirectoryURL(String)
        case nonFileLogURL(String)
    }

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

    public func spawnDetachedForget(
        executable: URL, arguments: [String], environment: [String: String],
        currentDirectory: URL?, logURL: URL) {
        // Synchronous fork+exec, no wait — the child is a separate process that survives our own exit(0).
        // Best-effort: at app-quit there's no one to surface an error to.
        _ = try? Self.spawnSync(
            executable: executable, arguments: arguments,
            environment: environment, currentDirectory: currentDirectory, logURL: logURL)
    }

    public func isRunning(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        // kill(pid, 0): 0 → alive & signalable; EPERM → alive but not ours; ESRCH → gone.
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    public func startTime(pid: Int32) -> Date? {
        guard pid > 0 else { return nil }
        // KERN_PROC_PID fills a `kinfo_proc` for one PID. A missing PID returns rc 0 but leaves `size` 0
        // (the record isn't written), so the size check — not just rc — is what distinguishes dead/unknown.
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let rc = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard rc == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        guard tv.tv_sec != 0 || tv.tv_usec != 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    public func terminate(pid: Int32) {
        guard pid > 0 else { return }
        kill(pid, SIGTERM)
    }

    public func observeExit(pid: Int32, onExit: @escaping @Sendable () -> Void) -> any ProcessObservation {
        guard pid > 0 else { return NoopObservation() }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler(handler: onExit)
        // No cancel handler (unlike FileWatch): a process source owns no descriptor we opened, so
        // cancelling/deallocating the DispatchObservation tears it down completely — nothing to close.
        source.resume()
        return DispatchObservation(source)
    }

    // MARK: - Synchronous workers (run on a background queue)

    /// Loader-injection vectors stripped from the FINAL environment — both the inherited ambient env AND
    /// Silo's overrides — so neither a hostile ambient env nor a user's `EnvFlags.extra` escape hatch can
    /// force a dylib into the wine child. We do NOT strip `DYLD_FALLBACK_LIBRARY_PATH`/
    /// `DYLD_FALLBACK_FRAMEWORK_PATH` — Silo sets those explicitly (they only add *fallback* search paths,
    /// not forced loads), and Silo never legitimately sets a denylisted key, so stripping it is loss-free.
    static let injectionDenylist: Set<String> = ["DYLD_INSERT_LIBRARIES", "DYLD_FORCE_FLAT_NAMESPACE"]

    static func mergedEnvironment(_ overrides: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for (key, value) in overrides { env[key] = value }
        for key in injectionDenylist { env[key] = nil }   // applied LAST → also strips a user-set override
        return env
    }

    private static func runSync(
        executable: URL, arguments: [String],
        environment: [String: String], currentDirectory: URL?
    ) throws -> ProcessResult {
        try validate(executable: executable, currentDirectory: currentDirectory)
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
        try validate(executable: executable, currentDirectory: currentDirectory)
        guard logURL.isFileURL else { throw RunnerError.nonFileLogURL(logURL.absoluteString) }
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

    private static func validate(executable: URL, currentDirectory: URL?) throws {
        guard executable.isFileURL else {
            throw RunnerError.nonFileExecutableURL(executable.absoluteString)
        }
        if let currentDirectory, !currentDirectory.isFileURL {
            throw RunnerError.nonFileCurrentDirectoryURL(currentDirectory.absoluteString)
        }
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
