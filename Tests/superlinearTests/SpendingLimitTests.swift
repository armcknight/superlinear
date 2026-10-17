import Foundation
import Testing
@testable import superlinear

// When the GitHub Actions spending limit is used up, CI in private
// repositories fails without running. That is not a failure to fix: it must
// be told apart from a real one, shown, and rerun once the limit is raised.
@Suite("GitHub Actions spending limit")
struct SpendingLimitTests {
    private let now = ISO8601DateFormatter().date(from: "2026-10-16T10:00:00Z")!
    private let noPauses = Standup.Pauses(claude: nil, waiting: [], spendingLimit: nil)

    private func stop(since: Date, runs: [StoppedRun], probe: StoppedRun? = nil) -> SpendingLimitStop {
        SpendingLimitStop(since: since, runs: runs, lastRerunAt: since, probe: probe)
    }

    private func run(
        _ id: WorkflowRun.ID, branch: String = "feature", workflow: String = "ci", status: WorkflowRun.Status = .completed,
        conclusion: WorkflowRun.Conclusion? = .failure, minutesAgo: Double = 0, attempt: Int = 1
    ) -> WorkflowRunSummary {
        WorkflowRunSummary(
            databaseId: id, headBranch: branch, workflowName: workflow, status: status, conclusion: conclusion,
            createdAt: now.addingTimeInterval(-minutesAgo * 60), attempt: attempt)
    }

    @Test("The spending-limit annotation is told apart from a real CI failure")
    func annotation() {
        #expect(SpendingLimit.isStopAnnotation(
            "The job was not started because recent account payments have failed or your spending limit needs to be "
                + "increased. Please check the 'Billing & plans' section of your settings"))
        #expect(SpendingLimit.isStopAnnotation("The job was not started because your account is locked due to a billing issue."))
        #expect(!SpendingLimit.isStopAnnotation("Process completed with exit code 1."))
        #expect(!SpendingLimit.isStopAnnotation("BillingTests.testSpendingLimit failed"))
        #expect(!SpendingLimit.isStopAnnotation("The operation was canceled."))
    }

    @Test("Only the latest run of each workflow on a watched branch counts, when it failed")
    func failingRuns() {
        let runs = [
            run(1, minutesAgo: 30),
            run(2, conclusion: .success, minutesAgo: 10),
            run(3, branch: "main", minutesAgo: 5),
            run(4, branch: "main", workflow: "lint", conclusion: .startupFailure, minutesAgo: 6),
            run(5, branch: "elsewhere", minutesAgo: 1),
            run(6, branch: "other", status: .inProgress, conclusion: nil),
            run(7, branch: "other", conclusion: nil, minutesAgo: 1),
        ]
        let failing = SpendingLimit.failingRuns(runs, branches: ["feature", "main", "other"])
        #expect(failing.map(\.databaseId) == [3, 4])
    }

    @Test("A run is read from gh run list, with an empty conclusion for one still going")
    func decoding() throws {
        let data = Data(#"""
            [{"databaseId": 7, "headBranch": "b", "workflowName": "ci", "status": "in_progress", "conclusion": "",
              "createdAt": "2026-10-16T09:00:00Z", "attempt": 2},
             {"databaseId": 8, "headBranch": "b", "status": "brand_new", "conclusion": "brand_new",
              "createdAt": "2026-10-16T09:00:00Z"}]
            """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let runs = try decoder.decode([WorkflowRunSummary].self, from: data)
        #expect(runs == [
            run(7, branch: "b", status: .inProgress, conclusion: nil, minutesAgo: 60, attempt: 2),
            WorkflowRunSummary(
                databaseId: 8, headBranch: "b", workflowName: nil, status: .unknown, conclusion: nil,
                createdAt: now.addingTimeInterval(-3600), attempt: nil),
        ])
    }

    @Test("A stop starts with the runs found, keeps its start, and ends when none are left")
    func updates() {
        let stopped = [StoppedRun(run(1, minutesAgo: 30)), StoppedRun(run(2, branch: "main", minutesAgo: 5))]
        let stop = SpendingLimitStop.updated(nil, stopped: stopped, now: now)
        #expect(stop?.since == now)
        #expect(stop?.lastRerunAt == now)
        #expect(stop?.runs.map(\.id) == [2, 1])
        let later = SpendingLimitStop.updated(stop, stopped: [stopped[0]], now: now.addingTimeInterval(600))
        #expect(later?.since == now)
        #expect(later?.runs.map(\.id) == [1])
        #expect(SpendingLimitStop.updated(stop, stopped: [], now: now) == nil)
        #expect(SpendingLimitStop.updated(nil, stopped: [], now: now) == nil)
    }

    @Test("One stopped run, the newest, is rerun each hour")
    func hourlyRerun() {
        var stop = stop(since: now, runs: [StoppedRun(run(2, minutesAgo: 5)), StoppedRun(run(1, minutesAgo: 30))])
        #expect(stop.runToProbe(now: now.addingTimeInterval(59 * 60)) == nil)
        #expect(stop.runToProbe(now: now.addingTimeInterval(60 * 60))?.id == 2)
        stop.probe = stop.runs[0]
        // None more while the rerun is watched.
        #expect(stop.runToProbe(now: now.addingTimeInterval(3 * 60 * 60)) == nil)
    }

    @Test("A probe that is watched stays, though its run no longer fails")
    func probeStays() {
        let probe = StoppedRun(run(2, minutesAgo: 5))
        let stop = stop(since: now, runs: [probe], probe: probe)
        #expect(SpendingLimitStop.updated(stop, stopped: [], now: now)?.runs == [probe])
    }

    @Test("The probe is read first at a poll, then the runs the owner may have rerun by hand")
    func watched() {
        let runs = [StoppedRun(run(3, minutesAgo: 1)), StoppedRun(run(2, minutesAgo: 2)), StoppedRun(run(1, minutesAgo: 3))]
        #expect(stop(since: now, runs: runs).watched == runs)
        #expect(stop(since: now, runs: runs, probe: runs[1]).watched.map(\.id) == [2, 3, 1])
    }

    @Test("The rerun's result: started, stopped again, or not yet known")
    func probeResults() async {
        let stopped: () async -> Bool? = { true }
        let ran: () async -> Bool? = { false }
        #expect(await SpendingLimit.probeResult(nil, rerunFrom: 1, stopped: stopped) == .pending)
        #expect(await SpendingLimit.probeResult(run(1, attempt: 1), rerunFrom: 1, stopped: stopped) == .pending)
        #expect(await SpendingLimit.probeResult(
            run(1, status: .queued, conclusion: nil, attempt: 2), rerunFrom: 1, stopped: stopped) == .pending)
        #expect(await SpendingLimit.probeResult(
            run(1, status: .inProgress, conclusion: nil, attempt: 2), rerunFrom: 1, stopped: stopped) == .started)
        #expect(await SpendingLimit.probeResult(
            run(1, conclusion: .success, attempt: 2), rerunFrom: 1, stopped: stopped) == .started)
        #expect(await SpendingLimit.probeResult(run(1, attempt: 2), rerunFrom: 1, stopped: stopped) == .stillStopped)
        // It ran, and failed for a real reason: the limit was raised.
        #expect(await SpendingLimit.probeResult(run(1, attempt: 2), rerunFrom: 1, stopped: ran) == .started)
        #expect(await SpendingLimit.probeResult(run(1, attempt: 2), rerunFrom: 1, stopped: { nil }) == .pending)
    }

    @Test("Once a rerun's jobs start, the other runs are rerun newest first, one for each branch")
    func resumeOthers() {
        let runs = [
            StoppedRun(run(5, branch: "a", minutesAgo: 1)),
            StoppedRun(run(4, branch: "b", minutesAgo: 2)),
            StoppedRun(run(3, branch: "a", workflow: "lint", minutesAgo: 3)),
            StoppedRun(run(2, branch: "c", minutesAgo: 4)),
            StoppedRun(run(1, branch: "b", workflow: "lint", minutesAgo: 5)),
        ]
        let stop = stop(since: now, runs: runs, probe: runs[1])
        #expect(stop.othersToRerun(after: runs[1]).map(\.id) == [5, 2])
        // A run the owner reran by hand counts the same as the probe.
        #expect(stop.othersToRerun(after: runs[3]).map(\.id) == [5, 4])
    }

    @Test("A pull request stopped by the limit shows CI not started, not CI failing")
    func checkState() {
        func pullRequest(_ branch: String, conclusion: String) -> ReviewablePullRequest {
            ReviewablePullRequest(
                number: 1, url: "u", title: "t", headRefName: branch, isDraft: false, reviewDecision: nil,
                latestReviews: nil, statusCheckRollup: [.init(status: "COMPLETED", conclusion: conclusion)])
        }
        #expect(pullRequest("a", conclusion: "FAILURE").checkState(stoppedBranches: ["a"]) == .notStarted)
        #expect(pullRequest("a", conclusion: "FAILURE").checkState(stoppedBranches: ["a"]).rawValue
            == "CI not started: GitHub spending limit")
        #expect(pullRequest("b", conclusion: "FAILURE").checkState(stoppedBranches: ["a"]) == .failing)
        #expect(pullRequest("a", conclusion: "SUCCESS").checkState(stoppedBranches: ["a"]) == .passing)
    }

    @Test("Status shows one line for the repositories whose CI stopped")
    func statusLine() {
        var state = State()
        state.workspaces["w", default: WorkspaceState()].spendingLimit = stop(since: now, runs: [StoppedRun(run(1))])
        state.workspaces["x", default: WorkspaceState()].spendingLimit = stop(
            since: now.addingTimeInterval(60), runs: [StoppedRun(run(2))])
        let lines = StatusCommand.pauseLines(state: state, workspaces: ["w", "x"], now: now)
        #expect(lines.count == 1)
        #expect(lines[0].hasPrefix("GitHub Actions spending limit: CI not started in 2 repositories since "))
        #expect(StatusCommand.pauseLines(state: state, workspaces: ["w"], now: now)[0].contains("in 1 repository since"))
    }

    @Test("The standup's risks list both pauses and the work they hold back")
    func risks() {
        let pauses = Standup.Pauses(
            claude: ClaudePause(
                since: now, until: .init(rawValue: now.addingTimeInterval(3600)), nextCheckAt: now.addingTimeInterval(900)),
            waiting: ["SPL-1", "SPL-2"],
            spendingLimit: stop(since: now, runs: [StoppedRun(run(1, branch: "main"))]))
        let failing = Standup.DefaultBranchRun(status: .completed, conclusion: .failure, url: "https://ci/1", workflowName: "ci")
        let risks = Standup.risks(defaultBranch: "main", latestRun: failing, rateLimit: nil, pauses: pauses, now: now)
        #expect(risks.count == 2)
        #expect(risks[0].hasPrefix("Claude usage limit: sessions paused until "))
        #expect(risks[0].hasSuffix("holds back SPL-1, SPL-2"))
        #expect(risks[1].hasPrefix("GitHub Actions spending limit: CI not started since "))
        #expect(risks[1].contains("on main;"))
        // Without the stop, the default branch's failure is a real one.
        #expect(Standup.risks(defaultBranch: "main", latestRun: failing, rateLimit: nil, pauses: noPauses, now: now)
            == ["CI failure on main (ci): https://ci/1"])
    }

    @Test("The standup's pauses come from the state file, the Claude pause only while it lasts")
    func pausesFromState() {
        var state = State()
        state.claudePause = ClaudePause(since: now, until: .init(rawValue: now.addingTimeInterval(3600)), nextCheckAt: now)
        state.recordRun(AgentRun(issueId: "i", identifier: "SPL-9", branchName: "b", sessionId: "s"), workspace: "w")
        let pauses = Standup.Pauses(state: state, workspace: "w", now: now)
        #expect(pauses.claude != nil)
        #expect(pauses.waiting == ["SPL-9"])
        #expect(Standup.Pauses(state: state, workspace: "w", now: now.addingTimeInterval(3600)).claude == nil)
    }

    @Test("The standup offers to resume Claude sessions once, when they are paused")
    func offerResume() {
        final class IO: StandupIO, @unchecked Sendable {
            var answers: [String?]
            var said: [String] = []
            var asked: [String] = []
            init(_ answers: [String?]) { self.answers = answers }
            func say(_ text: String) { said.append(text) }
            func ask(_ prompt: String) -> String? { asked.append(prompt); return answers.isEmpty ? nil : answers.removeFirst() }
            func edit(_ text: String) -> String? { text }
        }
        var state = State()
        let none = IO(["y"])
        StandupCommand.offerResume(state: state, io: none, resume: { _ in "resumed" }, now: now)
        #expect(none.asked.isEmpty)

        state.claudePause = ClaudePause(since: now, until: .init(rawValue: now.addingTimeInterval(3600)), nextCheckAt: now)
        let yes = IO(["y"])
        StandupCommand.offerResume(state: state, io: yes, resume: { _ in "resumed" }, now: now)
        #expect(yes.asked.count == 1)
        #expect(yes.said == ["resumed"])
        let no = IO([""])
        StandupCommand.offerResume(state: state, io: no, resume: { _ in "resumed" }, now: now)
        #expect(no.said.isEmpty)
    }

    @Test("Notifications quote their text for AppleScript")
    func notification() {
        #expect(Notifier.script(title: Notifier.title, message: #"Say "hi" \ bye"#)
            == #"display notification "Say \"hi\" \\ bye" with title "superlinear""#)
    }
}
