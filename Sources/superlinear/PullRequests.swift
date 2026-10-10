import Foundation

/// An issue whose agent has ended, watched until the pull request it opened is
/// merged or closed. Kept in the state file, so a restart keeps watching.
struct PendingMerge: Codable, Sendable, Equatable {
    var issueId: String
    var identifier: String
    var branchName: String

    init(issueId: String, identifier: String, branchName: String) {
        self.issueId = issueId
        self.identifier = identifier
        self.branchName = branchName
    }

    init(_ run: AgentRun) {
        self.init(issueId: run.issueId, identifier: run.identifier, branchName: run.branchName)
    }
}

/// A pull request as `gh pr list --json number,url,state` reports it.
struct PullRequest: Decodable, Sendable, Equatable {
    enum State: String, Decodable, Sendable {
        case open = "OPEN"
        case closed = "CLOSED"
        case merged = "MERGED"
    }

    let number: Int
    let url: String
    let state: State
}

/// What a poll found for an issue awaiting its merge.
enum MergeStatus: Equatable {
    /// The pull request is still open. Check again next poll.
    case open
    /// The pull request was merged: the issue is done.
    case merged(PullRequest)
    /// The pull request was closed without a merge.
    case closed(PullRequest)
    /// The branch has no pull request: the agent ended without opening one.
    case missing

    /// Sorts the pull requests opened from an issue's branch. A branch can have
    /// more than one, as when a closed PR is opened again; a merge wins, then
    /// one still open.
    static func of(_ pullRequests: [PullRequest]) -> MergeStatus {
        if let merged = pullRequests.first(where: { $0.state == .merged }) { return .merged(merged) }
        if pullRequests.contains(where: { $0.state == .open }) { return .open }
        if let closed = pullRequests.first { return .closed(closed) }
        return .missing
    }
}

struct CommandError: Error, CustomStringConvertible {
    let command: [String]
    let status: Int32
    let output: String

    var description: String {
        "`\(command.joined(separator: " "))` exited \(status): \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

/// Asks GitHub about the pull requests agents opened, and tears down the
/// worktrees of the ones that merged.
struct PullRequestChecker: Sendable {
    /// The environment commands run in. `gh` and `work` are found through its
    /// PATH, as they are for agents.
    let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    static func listArguments(branch: String) -> [String] {
        ["gh", "pr", "list", "--head", branch, "--state", "all", "--json", "number,url,state"]
    }

    static func decodePullRequests(_ data: Data) throws -> [PullRequest] {
        try JSONDecoder().decode([PullRequest].self, from: data)
    }

    /// The pull requests opened from `branch` in the repository at `repoPath`.
    func pullRequests(branch: String, repoPath: String) async throws -> [PullRequest] {
        let output = try await run(Self.listArguments(branch: branch), in: repoPath)
        return try Self.decodePullRequests(output)
    }

    /// Removes the worktree and local branch with `work finish`, appending its
    /// output to `logFile`.
    func finishWorktree(branch: String, repoPath: String, logFile: String) async throws {
        let output = try await run(["work", "finish", branch], in: repoPath)
        if !FileManager.default.fileExists(atPath: logFile) {
            FileManager.default.createFile(atPath: logFile, contents: nil)
        }
        if let handle = FileHandle(forWritingAtPath: logFile) {
            handle.seekToEndOfFile()
            handle.write(output)
            try? handle.close()
        }
    }

    /// Runs `arguments` in `directory` and returns its standard output, or
    /// throws with its combined output when it fails.
    private func run(_ arguments: [String], in directory: String) async throws -> Data {
        let environment = environment
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            process.environment = environment
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            let errors = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw CommandError(
                    command: arguments,
                    status: process.terminationStatus,
                    output: String(decoding: errors + output, as: UTF8.self)
                )
            }
            return output
        }.value
    }
}
