import Foundation
import Testing
@testable import SiloKit

@Suite("SystemProcessRunner (real subprocesses)")
struct SystemProcessRunnerTests {
    let runner = SystemProcessRunner()

    @Test("Captures stdout and a zero exit code")
    func stdout() async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello"], environment: [:], currentDirectory: nil
        )
        #expect(result.succeeded)
        #expect(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    }

    @Test("Reports a non-zero exit code")
    func exitCode() async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 3"], environment: [:], currentDirectory: nil
        )
        #expect(result.exitCode == 3)
    }

    @Test("Captures stderr separately")
    func stderr() async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo oops 1>&2"], environment: [:], currentDirectory: nil
        )
        #expect(result.stderrString.contains("oops"))
        #expect(result.standardOutput.isEmpty)
    }

    @Test("Applies environment overrides")
    func environment() async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf %s \"$SILO_TEST\""],
            environment: ["SILO_TEST": "isolated"], currentDirectory: nil
        )
        #expect(result.stdoutString == "isolated")
    }

    @Test("mergedEnvironment strips loader-injection vars from BOTH inherited env and overrides, keeps DYLD_FALLBACK")
    func mergedEnvironmentScrubsInjection() async throws {
        // Simulate a hostile ambient env carrying a dylib-injection var, then assert the child env.
        setenv("DYLD_INSERT_LIBRARIES", "/tmp/evil.dylib", 1)
        setenv("DYLD_FORCE_FLAT_NAMESPACE", "1", 1)
        defer { unsetenv("DYLD_INSERT_LIBRARIES"); unsetenv("DYLD_FORCE_FLAT_NAMESPACE") }

        let merged = SystemProcessRunner.mergedEnvironment([
            "DYLD_FALLBACK_LIBRARY_PATH": "/runtime/lib:/usr/lib",
            "WINEPREFIX": "/p/220",
            "DYLD_INSERT_LIBRARIES": "/tmp/from-extra.dylib",   // a user-set EnvFlags.extra must ALSO be stripped
        ])
        // The classic injection vectors are removed — from the inherited env AND from the overrides.
        #expect(merged["DYLD_INSERT_LIBRARIES"] == nil)
        #expect(merged["DYLD_FORCE_FLAT_NAMESPACE"] == nil)
        // ...while Silo's explicit overrides (fallback path + prefix) survive on top.
        #expect(merged["DYLD_FALLBACK_LIBRARY_PATH"] == "/runtime/lib:/usr/lib")
        #expect(merged["WINEPREFIX"] == "/p/220")
    }

    @Test("spawnDetached writes child output to the log file")
    func spawnDetached() async throws {
        let tmp = try TempDir()
        defer { tmp.cleanup() }
        let logURL = tmp.url.appendingPathComponent("Logs/220.log")

        let pid = try await runner.spawnDetached(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["detached-hello"], environment: [:], currentDirectory: nil, logURL: logURL
        )
        #expect(pid > 0)

        // Detached: poll the log until the child has flushed (bounded wait).
        var contents = ""
        for _ in 0..<40 {
            contents = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            if contents.contains("detached-hello") { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(contents.contains("detached-hello"))
    }

    @Test("rejects non-file process URLs without raising an Objective-C exception")
    func rejectsNonFileURLs() async {
        let malformed = URL(string: "/Users/example/wine64")!
        await #expect(throws: SystemProcessRunner.RunnerError.nonFileExecutableURL(malformed.absoluteString)) {
            _ = try await runner.run(
                executable: malformed, arguments: ["--version"], environment: [:], currentDirectory: nil)
        }

        let log = URL(fileURLWithPath: "/tmp/silo-test.log")
        await #expect(throws: SystemProcessRunner.RunnerError.nonFileExecutableURL(malformed.absoluteString)) {
            _ = try await runner.spawnDetached(
                executable: malformed, arguments: [], environment: [:], currentDirectory: nil, logURL: log)
        }
    }
}

@Suite("FakeProcessRunner")
struct FakeProcessRunnerTests {

    @Test("Records invocations and returns the default result")
    func records() async throws {
        let fake = FakeProcessRunner()
        let result = try await fake.run(
            executable: URL(fileURLWithPath: "/w/wine"),
            arguments: ["wineboot", "--init"],
            environment: ["WINEPREFIX": "/p/220"], currentDirectory: nil
        )
        #expect(result.succeeded)
        #expect(fake.invocations.count == 1)
        #expect(fake.lastInvocation?.arguments == ["wineboot", "--init"])
        #expect(fake.lastInvocation?.environment["WINEPREFIX"] == "/p/220")
        #expect(fake.lastInvocation?.detached == false)
    }

    @Test("Returns scripted results in FIFO order")
    func scripted() async throws {
        let fake = FakeProcessRunner()
        fake.queueResult(ProcessResult(exitCode: 1, standardError: Data("boom".utf8)))
        let result = try await fake.run(
            executable: URL(fileURLWithPath: "/x"), arguments: [], environment: [:], currentDirectory: nil
        )
        #expect(result.exitCode == 1)
        #expect(result.stderrString == "boom")
    }

    @Test("Runs the side-effect hook and records detached spawns")
    func hookAndSpawn() async throws {
        let fake = FakeProcessRunner()
        let tmp = try TempDir()
        defer { tmp.cleanup() }
        let regURL = tmp.url.appendingPathComponent("system.reg")   // URL is Sendable; TempDir is not
        // Simulate wineboot creating system.reg.
        fake.onRun = { inv in
            if inv.arguments.contains("--init") {
                try? "WINE REGISTRY".write(to: regURL, atomically: true, encoding: .utf8)
            }
        }
        _ = try await fake.run(
            executable: URL(fileURLWithPath: "/w/wine"), arguments: ["wineboot", "--init"],
            environment: [:], currentDirectory: nil
        )
        #expect(FileManager.default.fileExists(atPath: regURL.path))

        let pid = try await fake.spawnDetached(
            executable: URL(fileURLWithPath: "/w/wine"), arguments: ["game.exe"],
            environment: [:], currentDirectory: nil, logURL: tmp.url.appendingPathComponent("g.log")
        )
        #expect(pid == 4242)
        #expect(fake.lastInvocation?.detached == true)
        #expect(fake.lastInvocation?.logURL?.lastPathComponent == "g.log")
    }
}
