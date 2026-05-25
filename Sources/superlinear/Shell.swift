import Foundation

enum ShellError: Error {
    case nonZeroExit(Int32, String)
    case executableNotFound(String)
}

enum Shell {
    // Resolve `command` via PATH (using /usr/bin/env) rather than requiring an absolute path.
    @discardableResult
    static func run(
        command: String,
        arguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil
    ) async throws -> String {
        try await run("/usr/bin/env", arguments: [command] + arguments,
                      workingDirectory: workingDirectory, environment: environment)
    }

    static func runDetachedCommand(
        _ command: String,
        arguments: [String],
        workingDirectory: String?
    ) throws {
        try runDetached("/usr/bin/env", arguments: [command] + arguments,
                        workingDirectory: workingDirectory)
    }

    static func run(
        _ executable: String,
        arguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr

            if let workingDirectory {
                process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
            }
            if let environment {
                process.environment = environment
            }

            process.terminationHandler = { proc in
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outData + errData, encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: ShellError.nonZeroExit(proc.terminationStatus, output))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    static func runDetached(
        _ executable: String,
        arguments: [String],
        workingDirectory: String?
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        try process.run()
        // Intentionally not calling waitUntilExit() — fire and forget
    }
}
