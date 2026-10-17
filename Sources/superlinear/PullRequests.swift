import Foundation
import Tagged

/// An issue whose agent has ended, watched until the pull request it opened is
/// merged or closed. Kept in the state file, so a restart keeps watching.
struct PendingMerge: Codable, Sendable, Equatable {
    var issueId: String
    var identifier: LinearIssue.Identifier
    var branchName: String
    /// Reviews submitted at or before this time are taken as addressed: the
    /// last agent on the issue was already running when they came in. Absent
    /// in state files written before reviews were followed.
    var reviewsHandledThrough: Date?
    /// The last agent set to resolve the pull request's conflicts with its
    /// base branch, if that was the last agent on the issue.
    var conflictAttempt: ConflictAttempt?
    /// The GitHub issue's number, when the issue comes from GitHub.
    var gitHubIssue: Int? = nil

    init(
        issueId: String, identifier: LinearIssue.Identifier, branchName: String,
        reviewsHandledThrough: Date? = nil, conflictAttempt: ConflictAttempt? = nil, gitHubIssue: Int? = nil
    ) {
        self.issueId = issueId
        self.identifier = identifier
        self.branchName = branchName
        self.reviewsHandledThrough = reviewsHandledThrough
        self.conflictAttempt = conflictAttempt
        self.gitHubIssue = gitHubIssue
    }

    /// The watch that follows a run once its agent ends. Reviews from after
    /// the agent started are left to the next one; it may have read some of
    /// them, but a review it missed would otherwise go unanswered. A run that
    /// resolved conflicts read no reviews, so the baseline from before it
    /// stays.
    init(_ run: AgentRun) {
        let started = run.launchedAt ?? run.processStartedAt
        self.init(
            issueId: run.issueId, identifier: run.identifier, branchName: run.branchName,
            reviewsHandledThrough: run.conflict.map { $0.reviewsHandledThrough ?? started } ?? started,
            conflictAttempt: run.conflict?.attempt, gitHubIssue: run.gitHubIssue
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

/// A pull request as `gh pr list --json` reports it. Each poll lists a
/// repository's pull requests once, and its open ones with their reviews
/// and head commits once more; `superlinear status` lists a
/// whole repository and asks for the branch, draft flag and size as well.
struct PullRequest: Codable, Sendable, Equatable {
    typealias Number = Tagged<PullRequest, Int>

    enum State: String, Codable, Sendable {
        case open = "OPEN"
        case closed = "CLOSED"
        case merged = "MERGED"
    }

    let number: Number
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
    /// The commit its branch points at, when the listing asked for it.
    var headRefOid: String? = nil
    /// Lines added and removed, and files changed, when the listing asked.
    var additions: Int? = nil
    var deletions: Int? = nil
    var changedFiles: Int? = nil
    /// The branch it would merge into, when the listing asked.
    var baseRefName: String? = nil
    /// `MERGEABLE`, `CONFLICTING` or `UNKNOWN`, when the listing asked. GitHub
    /// works it out in the background after the base or branch moves, and
    /// says `UNKNOWN` until it has.
    var mergeable: String? = nil

    /// Whether GitHub found that it conflicts with its base branch.
    var conflicts: Bool { mergeable == "CONFLICTING" }
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

    static let listOpenArguments = [
        "gh", "pr", "list", "--state", "open", "--limit", "1000", "--json", "number,url,state,headRefName,headRefOid,reviews,mergeable,baseRefName",
    ]

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

    static func commitDateArguments(sha: String) -> [String] {
        ["gh", "api", "repos/{owner}/{repo}/commits/\(sha)", "--jq", ".commit.committer.date"]
    }

    /// When the commit `sha` was made, from GitHub's REST API, whose rate
    /// limit is apart from the GraphQL one the listings use.
    func commitDate(sha: String, repoPath: String) async throws -> Date {
        let arguments = Self.commitDateArguments(sha: sha)
        let text = String(decoding: try await run(arguments, in: repoPath), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let date = ISO8601DateFormatter().date(from: text) else {
            throw CommandError(command: arguments, status: 0, output: "no commit date in \(text)")
        }
        return date
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

    /// The repository's open pull requests, newest 1,000, with their
    /// reviews, which cost GitHub more to list than the rest, head commits,
    /// base branches and whether they conflict with them. Not their commit lists: those cost so much that GitHub
    /// refuses a page of 100 pull requests as over the rate limit.
    func openPullRequestsWithReviews(repoPath: String) async throws -> [PullRequest] {
        try Self.decodePullRequests(try await run(Self.listOpenArguments, in: repoPath))
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

/// A repository's pull requests for one poll, listed at most once each way
/// and shared by every step that needs them. GitHub allows 5,000 GraphQL
/// points an hour, shared with agents and with `superlinear status`; a
/// listing per branch per poll used them all up.
actor PullRequestListing {
    let repoPath: String
    let checker: PullRequestChecker
    // Failures are kept too, so a poll that hits the rate limit does not try
    // again for every branch.
    private var all: Result<[PullRequest], Error>?
    private var open: Result<[PullRequest], Error>?
    /// The heads of base branches on the remote, fetched once each.
    private var remoteHeads: [String: String?] = [:]

    init(repoPath: String, checker: PullRequestChecker = PullRequestChecker()) {
        self.repoPath = repoPath
        self.checker = checker
    }

    /// The pull requests opened from `branch`. Open ones come with their
    /// reviews and head commits.
    func pullRequests(branch: String) async throws -> [PullRequest] {
        let mine = try await allPullRequests().filter { $0.headRefName == branch }
        guard mine.contains(where: { $0.state == .open }) else { return mine }
        if open == nil { open = await Self.result { try await checker.openPullRequestsWithReviews(repoPath: repoPath) } }
        return Self.merge(mine, withOpen: try open!.get())
    }

    func allPullRequests() async throws -> [PullRequest] {
        if all == nil { all = await Self.result { try await checker.allPullRequests(repoPath: repoPath) } }
        return try all!.get()
    }

    /// The head of `branch` on `origin`, fetched first, so it is as new as
    /// the pull requests. Nil when git fails. Git asks no GitHub API, so the
    /// rate limits do not apply.
    func remoteHead(of branch: String) -> String? {
        if let head = remoteHeads[branch] { return head }
        let head = Git.run(["fetch", "--quiet", "origin", branch], in: repoPath)
            .flatMap { _ in Git.run(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(branch)^{commit}"], in: repoPath) }
        remoteHeads[branch] = head
        return head
    }

    private static func result(_ body: @Sendable () async throws -> [PullRequest]) async -> Result<[PullRequest], Error> {
        do {
            return .success(try await body())
        } catch {
            return .failure(error)
        }
    }

    /// Replaces each open pull request with its listing that has reviews and
    /// a head commit, where there is one.
    static func merge(_ pullRequests: [PullRequest], withOpen open: [PullRequest]) -> [PullRequest] {
        pullRequests.map { pullRequest in
            guard pullRequest.state == .open else { return pullRequest }
            return open.first { $0.number == pullRequest.number } ?? pullRequest
        }
    }
}
