import Foundation
import Testing
@testable import superlinear

// Shell is how the daemon starts every agent. If a non-zero exit were reported
// as success, a failed `work start` would be marked processed and the issue
// would never be retried.
@Suite("Shell")
struct ShellTests {
    @Test("Standard output comes back on success")
    func capturesStdout() async throws {
        let output = try await Shell.run(command: "echo", arguments: ["hello"])
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    }

    @Test("A non-zero exit throws, carrying the status")
    func nonZeroExitThrows() async throws {
        await #expect(throws: ShellError.self) {
            try await Shell.run(command: "false", arguments: [])
        }

        do {
            _ = try await Shell.run(command: "sh", arguments: ["-c", "exit 3"])
            Issue.record("expected a non-zero exit to throw")
        } catch let ShellError.nonZeroExit(status, _) {
            #expect(status == 3)
        }
    }

    // Both streams are collected, so a tool that reports errors on stderr and
    // then fails still surfaces something useful in the log.
    @Test("Standard error is captured too")
    func capturesStderr() async throws {
        do {
            _ = try await Shell.run(command: "sh", arguments: ["-c", "echo boom >&2; exit 1"])
            Issue.record("expected a non-zero exit to throw")
        } catch let ShellError.nonZeroExit(_, output) {
            #expect(output.contains("boom"))
        }
    }

    @Test("The working directory is honoured")
    func honoursWorkingDirectory() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("superlinear-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let output = try await Shell.run(
            command: "pwd", arguments: [], workingDirectory: temp.path
        )

        // The temporary directory resolves through /private on macOS.
        #expect(output.contains(temp.lastPathComponent))
    }

    @Test("The environment is passed through")
    func passesEnvironment() async throws {
        let output = try await Shell.run(
            command: "sh", arguments: ["-c", "echo $SUPERLINEAR_TEST"],
            environment: ["SUPERLINEAR_TEST": "set", "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""]
        )
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "set")
    }

    @Test("An unknown executable throws rather than hanging")
    func unknownExecutableThrows() async {
        await #expect(throws: (any Error).self) {
            try await Shell.run(command: "definitely-not-a-real-binary-xyz", arguments: [])
        }
    }
}
