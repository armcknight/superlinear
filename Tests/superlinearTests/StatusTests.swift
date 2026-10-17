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
        #expect(TaskCategory.of(run: launched, running: true, issue: nil, pullRequest: merged) == .running)
        #expect(TaskCategory.of(run: launched, running: false, issue: nil, pullRequest: merged) == .interrupted)
        #expect(TaskCategory.of(run: queued, running: false, issue: nil, pullRequest: merged) == .queued)
    }

    @Test("A run addressing a review has its own category while running or queued, and resumes as usual when interrupted")
    func addressingReview() {
        let request = ReviewRequest(number: 4, url: "https://github.com/o/r/pull/4")
        var running = launched
        running.review = request
        var waiting = queued
        waiting.review = request
        #expect(TaskCategory.of(run: running, running: true, issue: nil, pullRequest: nil) == .addressingReview)
        #expect(TaskCategory.of(run: waiting, running: false, issue: nil, pullRequest: nil) == .addressingReview)
        #expect(TaskCategory.of(run: running, running: false, issue: nil, pullRequest: nil) == .interrupted)
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
        #expect(TaskCategory.of(run: nil, running: false, issue: issue("SL-1"), pullRequest: pullRequest(1, state: "OPEN")) == .openPullRequest)
    }

    // The issue's own rule: merged is not enough, Linear must agree.
    @Test("A merged pull request is complete only once the Linear issue is done")
    func completionNeedsBoth() {
        let merged = pullRequest(1, state: "MERGED")
        #expect(TaskCategory.of(run: nil, running: false, issue: issue("SL-1", stateType: "completed"), pullRequest: merged) == .completed)
        #expect(TaskCategory.of(run: nil, running: false, issue: issue("SL-1", stateType: "started"), pullRequest: merged) == .merged)
        #expect(TaskCategory.of(run: nil, running: false, issue: issue("SL-1", stateType: "canceled"), pullRequest: merged) == .merged)
    }

    @Test("Without an open or merged pull request, the Linear state decides")
    func withoutPullRequest() {
        let closedPR = pullRequest(1, state: "CLOSED")
        #expect(TaskCategory.of(run: nil, running: false, issue: issue("SL-1"), pullRequest: nil) == .noPullRequest)
        #expect(TaskCategory.of(run: nil, running: false, issue: issue("SL-1"), pullRequest: closedPR) == .noPullRequest)
        #expect(TaskCategory.of(run: nil, running: false, issue: issue("SL-1", stateType: "completed"), pullRequest: nil) == .closed)
        #expect(TaskCategory.of(run: nil, running: false, issue: issue("SL-1", stateType: "canceled"), pullRequest: closedPR) == .closed)
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

    @Test("A pull request whose review an agent addresses says so under Waiting on you")
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
          Waiting on you
            SL-1  #4 Four
                  agent addressing review · no CI · https://github.com/o/r/pull/4
          Addressing review
            SL-1  One
                  queued, https://github.com/o/r/pull/4
        """)
    }

    @Test("An empty workspace says so, and warnings are shown")
    func emptyAndWarnings() {
        #expect(WorkspaceReport(name: "w", entries: [], warnings: []).rendered() == "w\n  No tasks")
        #expect(WorkspaceReport(name: "w", entries: [], warnings: ["no network"]).rendered() == "w\n  warning: no network")
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
