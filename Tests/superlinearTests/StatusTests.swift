import Foundation
import Testing
@testable import superlinear

// The status report is how you learn what the daemon did. A task listed as
// completed too early hides work that still needs a merge or a Linear update.
@Suite("Status report")
struct StatusTests {
    private func issue(_ id: String, branch: String = "b", stateType: String = "started", stateName: String = "In Progress") -> LinearIssueStatus {
        LinearIssueStatus(
            id: id, identifier: .init(rawValue: id), title: "Title \(id)", branchName: branch,
            state: .init(name: stateName, type: stateType)
        )
    }

    private func pullRequest(_ number: PullRequest.Number, branch: String = "b", state: String, draft: Bool = false) -> PullRequest {
        PullRequest(
            number: number, url: "https://github.com/o/r/pull/\(number)",
            state: PullRequest.State(rawValue: state)!, headRefName: branch, isDraft: draft
        )
    }

    private let launched = AgentRun(
        issueId: "SL-1", identifier: "SL-1", branchName: "b", sessionId: "s",
        pid: 42, processStartedAt: Date(timeIntervalSince1970: 1)
    )
    private let queued = AgentRun(issueId: "SL-1", identifier: "SL-1", branchName: "b", sessionId: "s")

    // MARK: Categories

    @Test("A run in flight is running, interrupted, or queued, whatever its pull request")
    func runsInFlight() {
        let merged = pullRequest(1, state: "MERGED")
        #expect(TaskCategory.of(run: launched, running: true, issue: nil, pullRequest: merged, pending: nil) == .running)
        #expect(TaskCategory.of(run: launched, running: false, issue: nil, pullRequest: merged, pending: nil) == .interrupted)
        #expect(TaskCategory.of(run: queued, running: false, issue: nil, pullRequest: merged, pending: nil) == .queued)
    }

    @Test("A run addressing a review has its own category while running or queued, and resumes as usual when interrupted")
    func addressingReview() {
        let request = ReviewRequest(number: 4, url: "https://github.com/o/r/pull/4")
        var running = launched
        running.review = request
        var waiting = queued
        waiting.review = request
        #expect(TaskCategory.of(run: running, running: true, issue: nil, pullRequest: nil, pending: nil) == .addressingReview)
        #expect(TaskCategory.of(run: waiting, running: false, issue: nil, pullRequest: nil, pending: nil) == .addressingReview)
        #expect(TaskCategory.of(run: running, running: false, issue: nil, pullRequest: nil, pending: nil) == .interrupted)
    }

    @Test("A review run's detail gives its pull request, and its log once launched")
    func addressingReviewDetail() {
        let request = ReviewRequest(number: 4, url: "https://github.com/o/r/pull/4")
        var running = launched
        running.review = request
        var waiting = queued
        waiting.review = request
        waiting.resumes = 1
        let detail = { (run: AgentRun, alive: Bool) in
            WorkspaceReport.entries(
                state: state(processed: ["SL-1"], inFlight: [run]),
                issues: [issue("SL-1")], pullRequests: [], runner: runner, isRunning: { _ in alive }
            ).first?.detail
        }
        #expect(detail(running, true) == "pid 42, log /home/.local/share/superlinear/logs/SL-1.log, https://github.com/o/r/pull/4")
        #expect(detail(waiting, false) == "queued, to resume, attempt 2, https://github.com/o/r/pull/4")
    }

    @Test("A finished task with an open pull request is listed with it")
    func openPullRequest() {
        #expect(TaskCategory.of(run: nil, running: false, issue: issue("SL-1"), pullRequest: pullRequest(1, state: "OPEN"), pending: nil) == .openPullRequest)
    }

    // The issue's own rule: merged is not enough, Linear must agree.
    @Test("A merged pull request is complete only once the Linear issue is done")
    func completionNeedsBoth() {
        let merged = pullRequest(1, state: "MERGED")
        #expect(TaskCategory.of(run: nil, running: false, issue: issue("SL-1", stateType: "completed"), pullRequest: merged, pending: nil) == .completed)
        #expect(TaskCategory.of(run: nil, running: false, issue: issue("SL-1", stateType: "started"), pullRequest: merged, pending: nil) == .merged)
        #expect(TaskCategory.of(run: nil, running: false, issue: issue("SL-1", stateType: "canceled"), pullRequest: merged, pending: nil) == .merged)
    }

    @Test("Without an open or merged pull request, the Linear state decides")
    func withoutPullRequest() {
        let closedPR = pullRequest(1, state: "CLOSED")
        #expect(TaskCategory.of(run: nil, running: false, issue: issue("SL-1"), pullRequest: nil, pending: nil) == .noPullRequest)
        #expect(TaskCategory.of(run: nil, running: false, issue: issue("SL-1"), pullRequest: closedPR, pending: nil) == .noPullRequest)
        #expect(TaskCategory.of(run: nil, running: false, issue: issue("SL-1", stateType: "completed"), pullRequest: nil, pending: nil) == .closed)
        #expect(TaskCategory.of(run: nil, running: false, issue: issue("SL-1", stateType: "canceled"), pullRequest: closedPR, pending: nil) == .closed)
    }

    // MARK: Pull requests

    @Test("An open pull request speaks for its branch over merged and closed ones")
    func bestPullRequest() {
        let prs = [
            pullRequest(1, state: "CLOSED"),
            pullRequest(2, state: "MERGED"),
            pullRequest(3, state: "OPEN"),
            pullRequest(4, branch: "other", state: "OPEN"),
        ]
        #expect(PullRequest.best(for: "b", among: prs)?.number == 3)
        #expect(PullRequest.best(for: "b", among: Array(prs.prefix(2)))?.number == 2)
        #expect(PullRequest.best(for: "missing", among: prs) == nil)
    }

    @Test("Of two closed pull requests, the newer wins")
    func newerClosedWins() {
        let prs = [pullRequest(5, state: "CLOSED"), pullRequest(9, state: "CLOSED")]
        #expect(PullRequest.best(for: "b", among: prs)?.number == 9)
    }

    @Test("gh's JSON decodes")
    func decodesGitHubJSON() throws {
        let json = #"[{"headRefName":"linear/sl-1","isDraft":true,"number":7,"state":"OPEN","url":"https://github.com/o/r/pull/7"}]"#
        let prs = try JSONDecoder().decode([PullRequest].self, from: Data(json.utf8))
        #expect(prs == [PullRequest(number: 7, url: "https://github.com/o/r/pull/7", state: .open, headRefName: "linear/sl-1", isDraft: true)])
    }

    @Test("Linear's issue status decodes, nested state included")
    func decodesLinearStatus() throws {
        let json = #"{"id":"u","identifier":"SL-1","title":"t","branchName":"b","state":{"name":"Done","type":"completed"}}"#
        let issue = try JSONDecoder().decode(LinearIssueStatus.self, from: Data(json.utf8))
        #expect(issue.isCompleted)
        #expect(issue.isClosed)
        #expect(issue.state.name == "Done")
    }

    // MARK: Entries

    private func state(processed: [String], inFlight: [AgentRun] = []) -> WorkspaceState {
        var state = WorkspaceState()
        state.processedIssueIds = Set(processed)
        for run in inFlight {
            state.inFlight[run.issueId] = run
        }
        return state
    }

    private let runner = AgentRunner(home: "/home", environment: [:])

    @Test("Entries match issues to pull requests by branch, sorted by category then identifier")
    func entriesAreMatchedAndSorted() {
        let entries = WorkspaceReport.entries(
            state: state(processed: ["SL-10", "SL-2", "SL-3"]),
            issues: [
                issue("SL-10", branch: "ten", stateType: "completed"),
                issue("SL-2", branch: "two"),
                issue("SL-3", branch: "three"),
            ],
            pullRequests: [
                pullRequest(10, branch: "ten", state: "MERGED"),
                pullRequest(2, branch: "two", state: "OPEN"),
                pullRequest(3, branch: "three", state: "OPEN"),
            ],
            runner: runner
        )
        #expect(entries.map(\.identifier) == ["SL-2", "SL-3", "SL-10"])
        #expect(entries.map(\.category) == [.openPullRequest, .openPullRequest, .completed])
        #expect(entries[0].detail == "https://github.com/o/r/pull/2")
    }

    @Test("A running entry points at the agent's log")
    func runningDetail() {
        let entries = WorkspaceReport.entries(
            state: state(processed: ["SL-1"], inFlight: [launched]),
            issues: [issue("SL-1")], pullRequests: [], runner: runner, isRunning: { _ in true }
        )
        #expect(entries.first?.category == .running)
        #expect(entries.first?.detail == "pid 42, log /home/.local/share/superlinear/logs/SL-1.log")
    }

    @Test("Issues Linear no longer returns are left out, unless in flight")
    func missingIssues() {
        let entries = WorkspaceReport.entries(
            state: state(processed: ["SL-1", "SL-9"], inFlight: [queued]),
            issues: [], pullRequests: [], runner: runner
        )
        #expect(entries.map(\.identifier) == ["SL-1"])
        #expect(entries.first?.category == .queued)
    }

    // Without pull requests a finished task cannot be told apart from one with
    // nothing to show, so it is not guessed at.
    @Test("When pull requests are unknown, only runs in flight are listed")
    func unknownPullRequests() {
        let entries = WorkspaceReport.entries(
            state: state(processed: ["SL-1", "SL-2"], inFlight: [queued]),
            issues: [issue("SL-1"), issue("SL-2")], pullRequests: nil, runner: runner
        )
        #expect(entries.map(\.identifier) == ["SL-1"])
    }

    // MARK: Rendering

    @Test("The report has a section per category in use, details indented under titles")
    func rendering() {
        let report = WorkspaceReport(
            name: "w",
            entries: [
                TaskEntry(identifier: "SL-2", title: "Two", category: .openPullRequest, detail: "https://x/2"),
                TaskEntry(identifier: "SL-10", title: "Ten", category: .completed, detail: nil),
            ],
            warnings: []
        )
        #expect(report.rendered() == """
        w
          Open pull requests
            SL-2   Two
                   https://x/2
          Completed
            SL-10  Ten
        """)
    }

    @Test("A pull request whose review an agent addresses says so under Awaiting review")
    func awaitingAgent() {
        let pullRequest = ReviewablePullRequest(
            number: 4, url: "https://github.com/o/r/pull/4", title: "Four", headRefName: "linear/sl-1",
            isDraft: false, reviewDecision: "CHANGES_REQUESTED", latestReviews: nil, statusCheckRollup: nil
        )
        let report = WorkspaceReport(
            name: "w",
            entries: [TaskEntry(identifier: "SL-1", title: "One", category: .addressingReview, detail: "queued, https://github.com/o/r/pull/4")],
            reviews: [ReviewEntry(issue: issue("SL-1"), pullRequest: pullRequest)],
            warnings: []
        )
        #expect(report.rendered() == """
        w
          Awaiting review
            SL-1  #4 Four
                  agent addressing review · no CI · https://github.com/o/r/pull/4
          Addressing review
            SL-1  One
                  queued, https://github.com/o/r/pull/4
        """)
        // The note follows the task the filter leaves out.
        #expect(report.filtered(to: [.awaitingReview]).rendered() == """
        w
          Awaiting review
            SL-1  #4 Four
                  agent addressing review · no CI · https://github.com/o/r/pull/4
        """)
    }

    @Test("A filtered report keeps the note on a draft whose lower pull request was closed")
    func filteredKeepsClosedBase() {
        let draft = ReviewablePullRequest(
            number: 2, url: "https://github.com/o/r/pull/2", title: "Two", headRefName: "b-2",
            isDraft: true, reviewDecision: nil, latestReviews: nil, statusCheckRollup: nil, baseRefName: "b-1"
        )
        let base = StackBase(
            identifier: "SL-1", branch: "b-1", number: 1, url: "https://github.com/o/r/pull/1", depth: 1, baseHead: nil, drafted: true
        )
        let report = WorkspaceReport(
            name: "w",
            entries: [TaskEntry(
                identifier: "SL-2", title: "Two", category: .blocked, detail: nil,
                pullRequest: pullRequest(2, branch: "b-2", state: "OPEN"), stack: base
            )],
            reviews: [ReviewEntry(issue: issue("SL-2"), pullRequest: draft)],
            warnings: []
        )
        let text = report.filtered(to: [.drafts]).rendered()
        #expect(!text.contains("Blocked"))
        #expect(text.contains("stacked on #1, closed without a merge: decide what becomes of it"))
    }

    @Test("An empty workspace says so, and warnings are shown")
    func emptyAndWarnings() {
        #expect(WorkspaceReport(name: "w", entries: [], warnings: []).rendered() == "w\n  No tasks")
        #expect(WorkspaceReport(name: "w", entries: [], warnings: ["no network"]).rendered() == "w\n  warning: no network")
    }

    // MARK: Filtering

    @Test("Every section has a distinct name that parses back")
    func sectionNames() {
        let names = StatusSection.all.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(names.first == "awaiting-review")
        #expect(names.last == "stale")
        for section in StatusSection.all {
            #expect(StatusSection(name: section.name) == section)
        }
        #expect(StatusSection(name: "Running") == nil)
    }

    @Test("A filter keeps the named sections, and the pull requests of what it keeps")
    func filtered() {
        let open = pullRequest(2, branch: "two", state: "OPEN")
        let merged = pullRequest(10, branch: "ten", state: "MERGED")
        let reviewable = ReviewablePullRequest(
            number: 2, url: open.url, title: "Two", headRefName: "two",
            isDraft: false, reviewDecision: nil, latestReviews: nil, statusCheckRollup: nil
        )
        let draft = ReviewablePullRequest(
            number: 3, url: "https://github.com/o/r/pull/3", title: "Three", headRefName: "three",
            isDraft: true, reviewDecision: nil, latestReviews: nil, statusCheckRollup: nil
        )
        let report = WorkspaceReport(
            name: "w",
            entries: [
                TaskEntry(identifier: "SL-1", title: "One", category: .running, detail: nil),
                TaskEntry(identifier: "SL-2", title: "Two", category: .openPullRequest, detail: open.url, pullRequest: open),
                TaskEntry(identifier: "SL-10", title: "Ten", category: .completed, detail: merged.url, pullRequest: merged),
            ],
            reviews: [ReviewEntry(issue: issue("SL-2"), pullRequest: reviewable), ReviewEntry(issue: issue("SL-3"), pullRequest: draft)],
            pullRequestStats: [
                PullRequestStats(url: open.url, merged: false),
                PullRequestStats(url: draft.url, merged: false),
                PullRequestStats(url: merged.url, merged: true),
            ],
            stale: [StaleBranch(branch: "old", reason: .merged(4), hasWorktree: false, lastCommit: nil, unpushedCommits: 0)],
            warnings: []
        )

        let running = report.filtered(to: [.task(.running)])
        #expect(running.entries.map(\.identifier) == ["SL-1"])
        #expect(running.reviews == nil)
        #expect(running.pullRequestStats.isEmpty)
        #expect(running.stale.isEmpty)
        #expect(running.rendered() == "w\n  Running\n    SL-1  One")

        let drafts = report.filtered(to: [.drafts, .task(.completed)])
        #expect(drafts.reviews?.map(\.pullRequest.number) == [3])
        #expect(drafts.entries.map(\.identifier) == ["SL-10"])
        #expect(drafts.pullRequestStats.map(\.url) == [draft.url, merged.url])

        // Not listed for review, the open pull request shows as a task.
        let openTasks = report.filtered(to: [.task(.openPullRequest), .stale])
        #expect(openTasks.rendered() == """
        w
          Open pull requests
            SL-2  Two
                  https://github.com/o/r/pull/2
          Stale branches and worktrees
            old
              merged in #4
        """)
        #expect(openTasks.pullRequestStats.map(\.url) == [open.url])
    }

    @Test("Blocked and human-labeled issues are listed from the state file, with their blockers and labels")
    func waitingIssues() {
        var workspaceState = state(processed: [])
        workspaceState.blocked = ["id-5": WaitingIssue(identifier: "SL-5", title: "Five", blockers: ["SL-3", "SL-4"])]
        workspaceState.needsHuman = ["id-6": WaitingIssue(identifier: "SL-6", title: "Six", labels: ["Spike"])]
        let entries = WorkspaceReport.entries(state: workspaceState, issues: [], pullRequests: nil, runner: runner)
        #expect(entries.map(\.category) == [.blocked, .needsHuman])
        #expect(WorkspaceReport(name: "w", entries: entries, warnings: []).rendered() == """
        w
          Blocked
            SL-5  Five
                  blocked by SL-3, SL-4
          Needs human
            SL-6  Six
                  labeled Spike
        """)
    }
}
