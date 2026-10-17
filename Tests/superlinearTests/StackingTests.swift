import Foundation
import Testing
@testable import superlinear

// A stacked issue starts on code that is not merged yet. Stacking on the
// wrong pull request, or rewriting one the owner reviewed, costs more than
// waiting, so the rules for when to stack and how to keep up are strict.
@Suite("Stacking")
struct StackingTests {
    private func workspace(_ extra: String = "") throws -> WorkspaceConfig {
        let json = #"{"workspaces": [{"name": "w", "apiKey": "k", "repoPath": "~/r"\#(extra)}]}"#
        return try #require(try Config.decoded(from: Data(json.utf8)).workspaces.first)
    }

    private func issue(_ identifier: LinearIssue.Identifier, blockers: [(LinearIssue.Identifier, String)] = []) -> LinearIssue {
        LinearIssue(
            id: "id-\(identifier)", identifier: identifier, title: "Title \(identifier)", branchName: "b-\(identifier)",
            createdAt: Date(timeIntervalSince1970: 0), team: .init(id: "t", key: "SL"),
            state: .init(name: "unstarted", type: "unstarted"),
            inverseRelations: .init(nodes: blockers.map { identifier, state in
                .init(type: "blocks", issue: .init(id: "id-\(identifier)", identifier: identifier, state: .init(type: state)))
            })
        )
    }

    private func pullRequest(
        _ number: PullRequest.Number, state: PullRequest.State = .open, branch: String = "b-SL-1", base: String = "main",
        draft: Bool = false, checks: [ReviewablePullRequest.Check]? = [.init(status: "COMPLETED", conclusion: "SUCCESS")],
        head: String = "aaa"
    ) -> PullRequest {
        PullRequest(
            number: number, url: "https://github.com/o/r/pull/\(number)", state: state, headRefName: branch, isDraft: draft,
            headRefOid: head, baseRefName: base, statusCheckRollup: checks
        )
    }

    private let blocker = PendingMerge(issueId: "id-SL-1", identifier: "SL-1", branchName: "b-SL-1")
    private let base = StackBase(identifier: "SL-1", branch: "b-SL-1", number: 1, url: "https://github.com/o/r/pull/1", depth: 1, baseHead: "aaa")

    // MARK: Selection

    @Test("Config: stacking is off by default, and the depth defaults to 3 and cannot go below 1")
    func config() throws {
        let byDefault = try workspace()
        #expect(byDefault.stacking == false)
        #expect(byDefault.maxStackDepth == 3)
        let configured = try workspace(#", "stacking": true, "maxStackDepth": 0"#)
        #expect(configured.stacking)
        #expect(configured.maxStackDepth == 1)
    }

    @Test("An issue with one open blocker whose pull request can be stacked on starts, stacked")
    func stackable() throws {
        let found = Stacking.base(on: blocker, pullRequest: pullRequest(1), maxDepth: 3)
        #expect(try found.get() == base)
        let plan = IssueSelection.plan(
            [issue("SL-2", blockers: [("SL-1", "started"), ("SL-0", "completed")])],
            workspace: try workspace(), handled: [], stackBases: ["SL-1": base]
        )
        #expect(plan.start.map(\.identifier) == ["SL-2"])
        #expect(plan.stacked["id-SL-2"] == base)
        #expect(plan.blocked.isEmpty)
    }

    @Test("Two unmerged blockers still wait, whatever their pull requests")
    func twoBlockersWait() throws {
        let plan = IssueSelection.plan(
            [issue("SL-3", blockers: [("SL-1", "started"), ("SL-2", "started")])],
            workspace: try workspace(), handled: [], stackBases: ["SL-1": base, "SL-2": base]
        )
        #expect(plan.start.isEmpty)
        #expect(plan.blocked["id-SL-3"]?.blockers == ["SL-1", "SL-2"])
        #expect(plan.stacked.isEmpty)
    }

    @Test("A draft, failing or running CI, no pull request, and a stack over the limit are not stackable")
    func notStackable() throws {
        let failing: [ReviewablePullRequest.Check] = [.init(status: "COMPLETED", conclusion: "FAILURE")]
        let running: [ReviewablePullRequest.Check] = [.init(status: "IN_PROGRESS", conclusion: nil)]
        #expect(Stacking.base(on: blocker, pullRequest: pullRequest(1, draft: true), maxDepth: 3) == .failure(.draft))
        #expect(Stacking.base(on: blocker, pullRequest: pullRequest(1, checks: failing), maxDepth: 3) == .failure(.ciNotPassing(.failing)))
        #expect(Stacking.base(on: blocker, pullRequest: pullRequest(1, checks: running), maxDepth: 3) == .failure(.ciNotPassing(.pending)))
        #expect(Stacking.base(on: blocker, pullRequest: pullRequest(1, checks: nil), maxDepth: 3) == .failure(.ciNotPassing(.none)))
        #expect(Stacking.base(on: blocker, pullRequest: nil, maxDepth: 3) == .failure(.noPullRequest))
        #expect(Stacking.base(on: blocker, pullRequest: pullRequest(1, state: .merged), maxDepth: 3) == .failure(.noPullRequest))
        // SL-1 is on main (depth 1); a stack of 2 is the most allowed here.
        #expect(Stacking.base(on: blocker, pullRequest: pullRequest(1), maxDepth: 2).isSuccess)
        var second = blocker
        second.stack = base
        #expect(second.stackDepth == 2)
        #expect(Stacking.base(on: second, pullRequest: pullRequest(2, branch: "b-SL-2", base: "b-SL-1"), maxDepth: 2) == .failure(.tooDeep(3)))
        let deeper = Stacking.base(on: second, pullRequest: pullRequest(2, branch: "b-SL-2", base: "b-SL-1"), maxDepth: 3)
        #expect(try deeper.get().depth == 2)
    }

    @Test("A stacked run's prompt names the lower pull request and targets its branch, without rewriting history")
    func prompt() {
        let run = AgentRun(issueId: "id-SL-2", identifier: "SL-2", branchName: "b-SL-2", sessionId: "s", stack: base)
        let prompt = AgentRunner.prompt(for: run)
        #expect(prompt.contains("https://github.com/o/r/pull/1"))
        #expect(prompt.contains("gh pr create --base b-SL-1"))
        #expect(prompt.contains("do not rebase, and do not force-push"))
        #expect(prompt.contains("/armcknight-claude:start"))
        // A review run on a stacked issue gets the review prompt.
        var review = run
        review.review = ReviewRequest(number: 2, url: "https://github.com/o/r/pull/2")
        #expect(AgentRunner.prompt(for: review).contains("has been reviewed"))
    }

    @Test("The stack follows the run into its merge watch, into review and conflict runs, and through the state file")
    func stackFollowsTheIssue() throws {
        let run = AgentRun(issueId: "id-SL-2", identifier: "SL-2", branchName: "b-SL-2", sessionId: "s", stack: base)
        let pending = PendingMerge(run)
        #expect(pending.stack == base)
        #expect(pending.stackDepth == 2)
        var state = State()
        state.recordRun(run, workspace: "w")
        state.awaitMerge(pending, workspace: "w")
        let loaded = try State.decoded(from: state.encoded())
        #expect(loaded.runs(workspace: "w").first?.stack == base)
        #expect(loaded.pendingMerges(workspace: "w").first?.stack == base)
        #expect(loaded.pendingMergesByIdentifier(workspace: "w")["SL-2"]?.stack == base)
        #expect(loaded.pendingMerge(branch: "b-SL-2", workspace: "w")?.identifier == "SL-2")
        state.updateStack(nil, issueId: "id-SL-2", workspace: "w")
        #expect(state.pendingMerges(workspace: "w").first?.stack == nil)
    }

    // MARK: Keeping a stack current

    private var upper: PullRequest { pullRequest(2, branch: "b-SL-2", base: "b-SL-1", head: "ccc") }

    @Test("A push to the lower branch restacks; nothing to do while it stays")
    func lowerMoved() {
        #expect(Stacking.action(for: base, pullRequest: upper, lower: [pullRequest(1)], lowerHead: "aaa", defaultBranch: "main") == .none)
        #expect(Stacking.action(for: base, pullRequest: upper, lower: [pullRequest(1)], lowerHead: "bbb", defaultBranch: "main") == .restack(head: "bbb"))
        // The remote could not be read: wait.
        #expect(Stacking.action(for: base, pullRequest: upper, lower: [pullRequest(1)], lowerHead: nil, defaultBranch: "main") == .none)
    }

    @Test("A merged lower pull request moves the upper one to what the lower targeted, retargeting it unless GitHub did")
    func lowerMerged() {
        let merged = pullRequest(1, state: .merged, base: "main")
        #expect(Stacking.action(for: base, pullRequest: upper, lower: [merged], lowerHead: nil, defaultBranch: "main")
            == .lowerMerged(base: "main", retarget: true))
        // Deeper down, the lower one targeted another stacked branch.
        let deeper = pullRequest(1, state: .merged, base: "b-SL-0")
        #expect(Stacking.action(for: base, pullRequest: upper, lower: [deeper], lowerHead: nil, defaultBranch: "main")
            == .lowerMerged(base: "b-SL-0", retarget: true))
        // GitHub retargeted it already when the lower branch was deleted.
        let retargeted = pullRequest(2, branch: "b-SL-2", base: "main")
        #expect(Stacking.action(for: base, pullRequest: retargeted, lower: [merged], lowerHead: nil, defaultBranch: "main")
            == .lowerMerged(base: "main", retarget: false))
    }

    @Test("A lower pull request closed without a merge drafts the upper one once, and reopening undoes it")
    func lowerClosed() {
        let closed = pullRequest(1, state: .closed)
        #expect(Stacking.action(for: base, pullRequest: upper, lower: [closed], lowerHead: "aaa", defaultBranch: "main") == .lowerClosed)
        var drafted = base
        drafted.drafted = true
        #expect(Stacking.action(for: drafted, pullRequest: upper, lower: [closed], lowerHead: "aaa", defaultBranch: "main") == .none)
        #expect(Stacking.action(for: drafted, pullRequest: upper, lower: [pullRequest(1)], lowerHead: "bbb", defaultBranch: "main") == .lowerReopened)
        // Closed and opened again as another pull request: open.
        #expect(Stacking.action(for: base, pullRequest: upper, lower: [closed, pullRequest(3)], lowerHead: "aaa", defaultBranch: "main") == .none)
        // Not in the listing at all: a gap, not a close.
        #expect(Stacking.action(for: base, pullRequest: upper, lower: [], lowerHead: "aaa", defaultBranch: "main") == .none)
    }

    @Test("The status puts the issue of a drafted upper pull request back under Blocked, with why")
    func statusAfterClose() throws {
        var drafted = base
        drafted.drafted = true
        let pending = PendingMerge(issueId: "id-SL-2", identifier: "SL-2", branchName: "b-SL-2", stack: drafted)
        let draft = pullRequest(2, branch: "b-SL-2", base: "b-SL-1", draft: true)
        #expect(TaskCategory.of(run: nil, running: false, issue: nil, pullRequest: draft, pending: pending) == .blocked)
        // Not once the owner decided.
        let plain = PendingMerge(issueId: "id-SL-2", identifier: "SL-2", branchName: "b-SL-2", stack: base)
        #expect(TaskCategory.of(run: nil, running: false, issue: nil, pullRequest: draft, pending: plain) == .openPullRequest)

        var workspaceState = WorkspaceState()
        workspaceState.processedIssueIds = ["id-SL-2"]
        workspaceState.pendingMerges = ["id-SL-2": pending]
        let issue = LinearIssueStatus(
            id: "id-SL-2", identifier: "SL-2", title: "Two", branchName: "b-SL-2", state: .init(name: "In Progress", type: "started"))
        let entries = WorkspaceReport.entries(state: workspaceState, issues: [issue], pullRequests: [draft], runner: AgentRunner(home: "/home"))
        #expect(entries.map(\.category) == [.blocked])
        #expect(entries.first?.detail == "blocked by SL-1: its pull request https://github.com/o/r/pull/1 was closed without a merge, "
            + "so https://github.com/o/r/pull/2 is a draft until you decide")
    }

    @Test("The status lists each pull request under the one it stacks on")
    func statusStacks() {
        func reviewable(_ number: PullRequest.Number, branch: String, base: String, draft: Bool = false) -> ReviewablePullRequest {
            ReviewablePullRequest(
                number: number, url: "https://github.com/o/r/pull/\(number)", title: "PR \(number)", headRefName: branch,
                isDraft: draft, reviewDecision: "", latestReviews: nil, statusCheckRollup: nil, baseRefName: base
            )
        }
        func issue(_ id: String, branch: String) -> LinearIssueStatus {
            LinearIssueStatus(id: id, identifier: .init(rawValue: id), title: id, branchName: branch, state: .init(name: "In Progress", type: "started"))
        }
        let report = WorkspaceReport(
            name: "w",
            entries: [],
            reviews: [
                ReviewEntry(issue: issue("SL-1", branch: "b-1"), pullRequest: reviewable(1, branch: "b-1", base: "main")),
                ReviewEntry(issue: issue("SL-3", branch: "b-3"), pullRequest: reviewable(3, branch: "b-3", base: "b-2")),
                ReviewEntry(issue: issue("SL-4", branch: "b-4"), pullRequest: reviewable(4, branch: "b-4", base: "main")),
                ReviewEntry(issue: issue("SL-2", branch: "b-2"), pullRequest: reviewable(2, branch: "b-2", base: "b-1")),
            ],
            warnings: []
        )
        #expect(report.rendered() == """
        w
          Awaiting review
            SL-1  #1 PR 1
                  not reviewed · no CI · https://github.com/o/r/pull/1
              SL-2  #2 PR 2
                    stacked on #1 · not reviewed · no CI · https://github.com/o/r/pull/2
                SL-3  #3 PR 3
                      stacked on #2 · not reviewed · no CI · https://github.com/o/r/pull/3
            SL-4  #4 PR 4
                  not reviewed · no CI · https://github.com/o/r/pull/4
        """)
    }

    @Test("The standup lists a draft whose lower pull request was closed, for a decision")
    func standupListsDraftedForDecision() {
        var drafted = base
        drafted.drafted = true
        var state = WorkspaceState()
        state.pendingMerges = ["id-SL-2": PendingMerge(issueId: "id-SL-2", identifier: "SL-2", branchName: "b-SL-2", stack: drafted)]
        let draft = ReviewablePullRequest(
            number: 2, url: "https://github.com/o/r/pull/2", title: "Two", headRefName: "b-SL-2", isDraft: true,
            reviewDecision: "", latestReviews: nil, statusCheckRollup: nil, baseRefName: "b-SL-1")
        let other = ReviewablePullRequest(
            number: 5, url: "https://github.com/o/r/pull/5", title: "Five", headRefName: "b-5", isDraft: true,
            reviewDecision: "", latestReviews: nil, statusCheckRollup: nil, baseRefName: "main")
        let waiting = Standup.waitingOnYou([draft, other], state: state)
        #expect(waiting.map(\.pullRequest.number) == [2])
        #expect(waiting.first?.baseClosed == 1)
        let text = StandupView.describe(waiting[0]).joined(separator: "\n")
        #expect(text.contains("draft: stacked on #1, closed without a merge; decide what becomes of it"))
    }

    // MARK: Git

    /// A bare origin with `main`, and clones of it, for the git operations.
    private struct Repos {
        let root: String
        let origin: String
        let clone: String
        let other: String

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("superlinear-stacks-\(UUID().uuidString)").path
            origin = "\(root)/origin.git"
            clone = "\(root)/clone"
            other = "\(root)/other"
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            try git("init", "--quiet", "--bare", "--initial-branch=main", origin, in: root)
            try git("clone", "--quiet", origin, other, in: root)
            try configure(other)
            try git("commit", "--quiet", "--allow-empty", "-m", "root", in: other)
            try git("push", "--quiet", "origin", "HEAD:main", in: other)
            try git("clone", "--quiet", origin, clone, in: root)
            try configure(clone)
        }

        func configure(_ path: String) throws {
            try git("config", "user.email", "t@example.com", in: path)
            try git("config", "user.name", "T", in: path)
        }

        @discardableResult
        func git(_ arguments: String..., in directory: String) throws -> String {
            let result = Git.result(arguments, in: directory)
            guard result.status == 0 else { throw StackingError("git \(arguments.joined(separator: " ")): \(result.output)") }
            return result.output
        }

        /// Commits `file` with `text` on `branch` in `other` and pushes it.
        func push(_ branch: String, file: String, text: String, from base: String? = nil) throws -> String {
            if let base {
                try git("fetch", "--quiet", "origin", base, in: other)
                try git("checkout", "--quiet", "-B", branch, "origin/\(base)", in: other)
            } else {
                try git("checkout", "--quiet", branch, in: other)
            }
            try text.write(toFile: "\(other)/\(file)", atomically: true, encoding: .utf8)
            try git("add", file, in: other)
            try git("commit", "--quiet", "-m", "\(branch): \(file)", in: other)
            try git("push", "--quiet", "origin", "HEAD:refs/heads/\(branch)", in: other)
            return try git("rev-parse", "HEAD", in: other)
        }

        func remove() { try? FileManager.default.removeItem(atPath: root) }
    }

    @Test("A stacked branch is created from the lower branch's head on the remote, once")
    func createBranch() throws {
        let repos = try Repos()
        defer { repos.remove() }
        let lowerHead = try repos.push("lower", file: "a.txt", text: "a", from: "main")
        #expect(try Stacking.createBranch("upper", from: "lower", repoPath: repos.clone) == lowerHead)
        #expect(try repos.git("rev-parse", "refs/heads/upper", in: repos.clone) == lowerHead)
        // Exists already, as after a resume: left alone, even when the lower branch moved.
        _ = try repos.push("lower", file: "b.txt", text: "b")
        #expect(try Stacking.createBranch("upper", from: "lower", repoPath: repos.clone) == nil)
        #expect(try repos.git("rev-parse", "refs/heads/upper", in: repos.clone) == lowerHead)
        #expect(throws: StackingError.self) { try Stacking.createBranch("another", from: "missing", repoPath: repos.clone) }
    }

    // The daemon merges, never rebases: the upper branch's own commit must
    // keep its hash, and the lower branch's new commit must be an ancestor.
    @Test("A push to the lower branch is merged into the upper branch with a merge commit and pushed")
    func restackAfterPush() throws {
        let repos = try Repos()
        defer { repos.remove() }
        _ = try repos.push("lower", file: "a.txt", text: "a", from: "main")
        let upperCommit = try repos.push("upper", file: "u.txt", text: "u", from: "lower")
        let worktree = "\(repos.clone)/worktrees/upper"
        try repos.git("fetch", "--quiet", "origin", in: repos.clone)
        try repos.git("worktree", "add", "--quiet", "--track", "-b", "upper", worktree, "origin/upper", in: repos.clone)

        let lowerHead = try repos.git("rev-parse", "refs/heads/lower", in: repos.other)
        #expect(try Stacking.mergeBase("lower", into: "upper", worktree: worktree) == .upToDate(baseHead: lowerHead))

        let moved = try repos.push("lower", file: "b.txt", text: "b")
        let outcome = try Stacking.mergeBase("lower", into: "upper", worktree: worktree)
        guard case .merged(let head, let baseHead) = outcome else { Issue.record("not merged: \(outcome)"); return }
        #expect(baseHead == moved)
        try repos.git("fetch", "--quiet", "origin", "upper", in: repos.other)
        #expect(try repos.git("rev-parse", "refs/remotes/origin/upper", in: repos.other) == head)
        #expect(try repos.git("rev-list", "--count", "--merges", "\(upperCommit)..\(head)", in: repos.other) == "1")
        #expect(try repos.git("merge-base", "--is-ancestor", moved, head, in: repos.other) == "")
        #expect(try repos.git("merge-base", "--is-ancestor", upperCommit, head, in: repos.other) == "")

        // A conflicting push is aborted and left to an agent; the worktree is as it was.
        _ = try repos.push("lower", file: "u.txt", text: "lower's u")
        #expect(try Stacking.mergeBase("lower", into: "upper", worktree: worktree) == .conflicted)
        #expect(try repos.git("status", "--porcelain", in: worktree) == "")
        #expect(try repos.git("rev-parse", "HEAD", in: worktree) == head)
    }

    // After a squash merge the upper branch still holds the lower branch's
    // commits; merging the new base in leaves only the upper's own diff.
    @Test("After the lower pull request merges, the new base is merged into the upper branch")
    func retargetAfterMerge() throws {
        let repos = try Repos()
        defer { repos.remove() }
        _ = try repos.push("lower", file: "a.txt", text: "a", from: "main")
        _ = try repos.push("upper", file: "u.txt", text: "u", from: "lower")
        // The squash merge of "lower" into main.
        try repos.git("checkout", "--quiet", "main", in: repos.other)
        try repos.git("merge", "--quiet", "--squash", "lower", in: repos.other)
        try repos.git("commit", "--quiet", "-m", "lower (#1)", in: repos.other)
        try repos.git("push", "--quiet", "origin", "HEAD:main", in: repos.other)
        try repos.git("push", "--quiet", "origin", "--delete", "lower", in: repos.other)

        let worktree = "\(repos.clone)/worktrees/upper"
        try repos.git("fetch", "--quiet", "origin", in: repos.clone)
        try repos.git("worktree", "add", "--quiet", "--track", "-b", "upper", worktree, "origin/upper", in: repos.clone)
        let outcome = try Stacking.mergeBase("main", into: "upper", worktree: worktree)
        guard case .merged(let head, _) = outcome else { Issue.record("not merged: \(outcome)"); return }
        try repos.git("fetch", "--quiet", "origin", in: repos.other)
        #expect(try repos.git("rev-parse", "refs/remotes/origin/upper", in: repos.other) == head)
        // Only the upper branch's own file differs from main now.
        #expect(try repos.git("diff", "--name-only", "origin/main", head, in: repos.other) == "u.txt")
    }
}

extension Result where Success == StackBase, Failure == NotStackable {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
