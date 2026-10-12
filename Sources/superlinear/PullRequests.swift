import Foundation

/// An issue whose agent has ended, watched until the pull request it opened is
/// merged or closed. Kept in the state file, so a restart keeps watching.
struct PendingMerge: Codable, Sendable, Equatable {
    var issueId: String
    var identifier: String
    var branchName: String
    /// Reviews submitted at or before this time are taken as addressed: the
    /// last agent on the issue was already running when they came in. Absent
    /// in state files written before reviews were followed.
    var reviewsHandledThrough: Date?

    init(issueId: String, identifier: String, branchName: String, reviewsHandledThrough: Date? = nil) {
        self.issueId = issueId
        self.identifier = identifier
        self.branchName = branchName
        self.reviewsHandledThrough = reviewsHandledThrough
    }

    /// The watch that follows a run once its agent ends. Reviews from after
    /// the agent started are left to the next one; it may have read some of
    /// them, but a review it missed would otherwise go unanswered.
    init(_ run: AgentRun) {
        self.init(
            issueId: run.issueId, identifier: run.identifier, branchName: run.branchName,
            reviewsHandledThrough: run.launchedAt ?? run.processStartedAt
        )
    }
}

/// A review on a pull request, as `gh pr list --json reviews` reports it.
struct PullRequestReview: Codable, Sendable, Equatable {
    struct Author: Codable, Sendable, Equatable {
        let login: String
    }

    let author: Author?
    /// `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, `DISMISSED` or `PENDING`.
    /// A string, so a state GitHub adds later does not fail the merge check
    /// that decodes it.
    let state: String
    let body: String
    let submittedAt: Date?

    /// Whether the review asks for anything: an approval with nothing written
    /// does not, and neither does a draft or a dismissed review.
    var asksForChanges: Bool {
        switch state {
        case "CHANGES_REQUESTED", "COMMENTED": true
        case "APPROVED": !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: false
        }
    }

    /// The reviews by `login`, submitted after `date`, that ask for changes.
    static func unaddressed(_ reviews: [PullRequestReview], by login: String, after date: Date) -> [PullRequestReview] {
        reviews.filter { review in
            guard review.author?.login == login, review.asksForChanges,
                  let submittedAt = review.submittedAt
            else { return false }
            return submittedAt > date
        }
    }
}

/// A pull request as `gh pr list --json` reports it. The merge check asks
/// for `number,url,state,reviews,commits` on one branch; `superlinear status` lists a
/// whole repository and asks for the branch, draft flag and size as well.
struct PullRequest: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable {
        case open = "OPEN"
        case closed = "CLOSED"
        case merged = "MERGED"
    }

    let number: Int
    let url: String
    let state: State
    /// The branch it was opened from, when the listing asked for it.
    var headRefName: String? = nil
    /// Whether it is a draft, when the listing asked for it.
    var isDraft: Bool? = nil
    /// When it merged, when the listing asked for it.
    var mergedAt: Date? = nil
    /// Its reviews, when the listing asked for them.
    var reviews: [PullRequestReview]? = nil
    /// Its commits, when the listing asked for them.
    var commits: [Commit]? = nil
    /// Lines added and removed, and files changed, when the listing asked.
    var additions: Int? = nil
    var deletions: Int? = nil
    var changedFiles: Int? = nil
    /// The branch it would merge into, when the listing asked.
    var baseRefName: String? = nil
}

extension PullRequest {
    struct Commit: Codable, Sendable, Equatable {
        let committedDate: Date
    }

    /// When its newest commit was made, if the listing asked for commits.
    var lastCommitDate: Date? { commits?.map(\.committedDate).max() }
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

/// Asks GitHub about the pull requests agents opened and the reviews left on
/// them, and tears down the worktrees of the ones that merged.
struct PullRequestChecker: Sendable {
    /// The environment commands run in. `gh` and `work` are found through its
    /// PATH, as they are for agents.
    let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    static func listArguments(branch: String) -> [String] {
        ["gh", "pr", "list", "--head", branch, "--state", "all", "--json", "number,url,state,reviews,commits"]
    }

    static let viewerArguments = ["gh", "api", "user", "--jq", ".login"]

    /// The GitHub login `gh` is signed in as, whose reviews agents answer.
    func viewerLogin(repoPath: String) async throws -> String {
        let login = String(decoding: try await run(Self.viewerArguments, in: repoPath), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !login.isEmpty else {
            throw CommandError(command: Self.viewerArguments, status: 0, output: "no login")
        }
        return login
    }

    static let listAllArguments = [
        "gh", "pr", "list", "--state", "all", "--limit", "1000", "--json", "number,url,state,headRefName,mergedAt",
    ]

    /// The repository's pull requests, newest 1,000, with their branches.
    func allPullRequests(repoPath: String) async throws -> [PullRequest] {
        try Self.decodePullRequests(try await run(Self.listAllArguments, in: repoPath))
    }

    static func decodePullRequests(_ data: Data) throws -> [PullRequest] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([PullRequest].self, from: data)
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
    func run(_ arguments: [String], in directory: String) async throws -> Data {
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
