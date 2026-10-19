import Foundation
import Testing
@testable import superlinear

// A pull request that conflicts with its base branch cannot merge. The daemon
// sets an agent to merge the base in, once for each pair of heads, so an
// agent that cannot resolve them is not started again every poll.
@Suite("Conflict resolution")
struct ConflictResolutionTests {
    private let request = ConflictRequest(
        number: 4, url: "https://github.com/o/r/pull/4", baseBranch: "main",
        attempt: ConflictAttempt(head: "aaa", base: "bbb"),
        reviewsHandledThrough: Date(timeIntervalSince1970: 50)
    )

    private func run(conflict: ConflictRequest?) -> AgentRun {
        AgentRun(
            issueId: "SL-1", identifier: "SL-1", branchName: "b", sessionId: "s",
            pid: 42, processStartedAt: Date(timeIntervalSince1970: 1),
            launchedAt: Date(timeIntervalSince1970: 100), conflict: conflict
        )
    }

    @Test("A conflict run gets a prompt that merges its base branch without rewriting history")
    func prompt() {
        let prompt = AgentRunner.prompt(for: run(conflict: request))
        #expect(prompt.contains("https://github.com/o/r/pull/4"))
        #expect(prompt.contains("git merge origin/main"))
        #expect(prompt.contains("Do not rebase and do not force-push"))
        #expect(prompt.contains("Do not post comments on GitHub"))
    }

    @Test("A conflict run on a GitHub issue reads the issue from GitHub, and its watch stays on GitHub")
    func gitHubIssue() {
        var gitHub = run(conflict: request)
        gitHub.gitHubIssue = 7
        let prompt = AgentRunner.prompt(for: gitHub)
        #expect(prompt.contains("git merge origin/main"))
        #expect(prompt.contains("gh issue view 7"))
        #expect(!prompt.contains("linctl"))
        #expect(PendingMerge(gitHub).gitHubIssue == 7)
        #expect(AgentRunner.prompt(for: run(conflict: request)).contains("linctl"))
    }

    // The conflict run reads no reviews: a review that came in before it must
    // still get an agent after it.
    @Test("The watch after a conflict run keeps the review baseline from before it, and the heads it tried")
    func watchAfterConflictRun() {
        let pending = PendingMerge(run(conflict: request))
        #expect(pending.reviewsHandledThrough == Date(timeIntervalSince1970: 50))
        #expect(pending.conflictAttempt == ConflictAttempt(head: "aaa", base: "bbb"))

        var noBaseline = request
        noBaseline.reviewsHandledThrough = nil
        #expect(PendingMerge(run(conflict: noBaseline)).reviewsHandledThrough == Date(timeIntervalSince1970: 100))

        let other = PendingMerge(run(conflict: nil))
        #expect(other.reviewsHandledThrough == Date(timeIntervalSince1970: 100))
        #expect(other.conflictAttempt == nil)
    }

    @Test("A conflict run and its watch survive the state file")
    func stateRoundTrip() throws {
        var state = State()
        state.recordRun(run(conflict: request), workspace: "w")
        state.awaitMerge(PendingMerge(run(conflict: request)), workspace: "w")
        let loaded = try State.decoded(from: state.encoded())
        #expect(loaded.runs(workspace: "w").first?.conflict == request)
        #expect(loaded.pendingMerges(workspace: "w").first?.conflictAttempt == request.attempt)
    }

    @Test("A conflict run has its own category while running or queued, and resumes as usual when interrupted")
    func category() {
        var queued = run(conflict: request)
        queued.pid = nil
        #expect(TaskCategory.of(run: run(conflict: request), running: true, issue: nil, pullRequest: nil, pending: nil) == .resolvingConflicts)
        #expect(TaskCategory.of(run: queued, running: false, issue: nil, pullRequest: nil, pending: nil) == .resolvingConflicts)
        #expect(TaskCategory.of(run: run(conflict: request), running: false, issue: nil, pullRequest: nil, pending: nil) == .interrupted)
    }

    @Test("GitHub's mergeable state is read from the open listing")
    func decodesMergeable() throws {
        let json = #"""
        [{"number":4,"url":"u4","state":"OPEN","mergeable":"CONFLICTING","baseRefName":"main"},
         {"number":5,"url":"u5","state":"OPEN","mergeable":"UNKNOWN"},
         {"number":6,"url":"u6","state":"OPEN"}]
        """#
        let pullRequests = try PullRequestChecker.decodePullRequests(Data(json.utf8))
        #expect(pullRequests.map(\.conflicts) == [true, false, false])
        #expect(pullRequests.first?.baseRefName == "main")
        #expect(PullRequestChecker.listOpenArguments.last?.contains("mergeable") == true)
    }

    @Test("A conflicting pull request says so under Waiting on you, and so does an agent resolving it")
    func rendered() {
        func pullRequest(_ number: PullRequest.Number, branch: String) -> ReviewablePullRequest {
            ReviewablePullRequest(
                number: number, url: "https://github.com/o/r/pull/\(number)", title: "PR \(number)",
                headRefName: branch, isDraft: false, reviewDecision: "", latestReviews: nil, statusCheckRollup: nil,
                baseRefName: "main", mergeable: "CONFLICTING"
            )
        }
        func issue(_ id: String) -> LinearIssueStatus {
            LinearIssueStatus(id: id, identifier: .init(rawValue: id), title: id, branchName: "b", state: .init(name: "In Progress", type: "started"))
        }
        let report = WorkspaceReport(
            name: "w",
            entries: [TaskEntry(identifier: "SL-1", title: "One", category: .resolvingConflicts, detail: "queued, https://github.com/o/r/pull/4")],
            reviews: [
                ReviewEntry(issue: issue("SL-1"), pullRequest: pullRequest(4, branch: "linear/sl-1")),
                ReviewEntry(issue: issue("SL-2"), pullRequest: pullRequest(5, branch: "linear/sl-2")),
            ],
            warnings: []
        )
        #expect(report.rendered() == """
        w
          Waiting on you
            SL-1  #4 PR 4
                  agent resolving conflicts · conflicts with main · no CI · https://github.com/o/r/pull/4
            SL-2  #5 PR 5
                  not reviewed · conflicts with main · no CI · https://github.com/o/r/pull/5
          Resolving conflicts
            SL-1  One
                  queued, https://github.com/o/r/pull/4
        """)
    }

    // GitHub's base commit for a pull request is the one at its last push, so
    // the base branch's head must come from the remote itself.
    @Test("The base branch's head is fetched from the remote")
    func remoteHead() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("superlinear-conflicts-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        func git(_ arguments: String..., in directory: String) throws -> String {
            try #require(Git.run(arguments, in: directory), "git \(arguments.joined(separator: " "))")
        }
        let origin = "\(root)/origin.git", clone = "\(root)/clone", other = "\(root)/other"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        _ = try git("init", "--quiet", "--bare", "--initial-branch=main", origin, in: root)
        for path in [clone, other] {
            _ = try git("clone", "--quiet", origin, path, in: root)
            _ = try git("config", "user.email", "t@example.com", in: path)
            _ = try git("config", "user.name", "T", in: path)
        }
        _ = try git("commit", "--quiet", "--allow-empty", "-m", "one", in: other)
        _ = try git("push", "--quiet", "origin", "HEAD:main", in: other)
        let first = try git("rev-parse", "HEAD", in: other)
        #expect(await PullRequestListing(repoPath: clone).remoteHead(of: "main") == first)

        _ = try git("commit", "--quiet", "--allow-empty", "-m", "two", in: other)
        _ = try git("push", "--quiet", "origin", "HEAD:main", in: other)
        let second = try git("rev-parse", "HEAD", in: other)
        let listing = PullRequestListing(repoPath: clone)
        #expect(await listing.remoteHead(of: "main") == second)
        #expect(await listing.remoteHead(of: "missing") == nil)
    }
}
