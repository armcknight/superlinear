import Foundation
import Testing
@testable import superlinear

private let now = Date(timeIntervalSince1970: 1_800_000_000)

/// A state file as the daemon writes it: activity over a few days, an
/// automatic proposal and two waiting in Linear, a chain of blocked issues
/// behind two that need a human, a queued run, and a review run.
private let stateFile = """
{"workspaces": {"w": {
  "processedIssueIds": ["i-q1", "i-r"],
  "lastPollTimestamp": "2027-01-15T07:00:00Z",
  "inFlight": {
    "i-q1": {"issueId": "i-q1", "identifier": "SPL-31", "branchName": "b31", "sessionId": "s1",
             "resumes": 0, "queuedAt": "2027-01-15T07:00:00Z"},
    "i-r": {"issueId": "i-r", "identifier": "SPL-20", "branchName": "b20", "sessionId": "s3", "pid": 42,
            "resumes": 0, "queuedAt": "2027-01-15T06:00:00Z", "launchedAt": "2027-01-15T06:00:00Z",
            "review": {"number": 20, "url": "https://github.com/o/r/pull/20"}}
  },
  "pendingMerges": {},
  "linkedPullRequests": {},
  "blocked": {
    "i-b1": {"identifier": "SPL-41", "title": "After the decision", "blockers": ["SPL-5"], "labels": []},
    "i-b2": {"identifier": "SPL-42", "title": "After that", "blockers": ["SPL-41"], "labels": []},
    "i-b3": {"identifier": "SPL-43", "title": "After the spike", "blockers": ["SPL-6"], "labels": []}
  },
  "needsHuman": {
    "i-h5": {"identifier": "SPL-5", "title": "Choose a database", "blockers": [], "labels": ["Needs human"]},
    "i-h6": {"identifier": "SPL-6", "title": "Spike the sync", "blockers": [], "labels": ["Spike"]}
  },
  "proposals": [
    {"id": "auto-1", "payload": {"addRelation": {"relatedIssueId": "i-b1", "type": "related"}},
     "target": {"kind": "issue", "id": "i-h5", "name": "SPL-5"}, "reason": "they touch the same code",
     "source": {"kind": "pullRequest", "value": "https://github.com/o/r/pull/9"},
     "createdAt": "2027-01-15T05:00:00Z", "status": "applied", "trust": "auto", "decidedAt": "2027-01-15T05:00:00Z"},
    {"id": "edit-1", "payload": {"editIssue": {"oldText": "Old plan", "newText": "New plan"}},
     "target": {"kind": "issue", "id": "i-h7", "name": "SPL-7"}, "reason": "the plan changed",
     "source": {"kind": "agentSession", "value": "abc"},
     "createdAt": "2027-01-15T04:00:00Z", "status": "pending", "trust": "review",
     "post": {"form": "comment", "issueId": "i-h7", "issueIdentifier": "SPL-7", "commentId": "c1",
              "url": "https://linear.app/t/issue/SPL-7#comment-c1", "postedAt": "2027-01-15T04:30:00Z"}},
    {"id": "new-1", "payload": {"createIssue": {"teamId": "t", "title": "Add retries", "description": ""}},
     "target": {"kind": "team", "id": "t"}, "reason": "flaky",
     "source": {"kind": "commitRange", "value": "a..b"},
     "createdAt": "2027-01-15T04:30:00Z", "status": "pending", "trust": "review",
     "post": {"form": "triageIssue", "issueId": "i-new", "issueIdentifier": "SPL-90",
              "url": "https://linear.app/t/issue/SPL-90", "postedAt": "2027-01-15T04:00:00Z"}},
    {"id": "unposted", "payload": {"closeIssue": {}},
     "target": {"kind": "issue", "id": "i-h6", "name": "SPL-6"}, "reason": "moot",
     "source": {"kind": "commitRange", "value": "a..b"},
     "createdAt": "2027-01-15T04:30:00Z", "status": "pending", "trust": "review"}
  ],
  "activity": [
    {"time": "2027-01-10T00:00:00Z", "kind": "agentStarted", "identifier": "SPL-1"},
    {"time": "2027-01-15T01:00:00Z", "kind": "agentFinished", "identifier": "SPL-2"},
    {"time": "2027-01-15T02:00:00Z", "kind": "conflictsResolved", "identifier": "SPL-3", "detail": "https://github.com/o/r/pull/3"},
    {"time": "2027-01-15T03:00:00Z", "kind": "issueCompleted", "identifier": "SPL-4", "detail": "https://github.com/o/r/pull/4"}
  ]
}}}
"""

private func loadState() throws -> WorkspaceState {
    try #require(State.decoded(from: Data(stateFile.utf8)).workspaces["w"])
}

private func pullRequest(_ number: PullRequest.Number, head: String, base: String = "main", draft: Bool = false) -> ReviewablePullRequest {
    ReviewablePullRequest(
        number: number, url: "https://github.com/o/r/pull/\(number)", title: "PR \(number)", headRefName: head,
        isDraft: draft, reviewDecision: nil, latestReviews: nil, statusCheckRollup: nil, baseRefName: base
    )
}

private func issue(_ identifier: String) -> LinearIssueStatus {
    LinearIssueStatus(
        id: identifier.lowercased(), identifier: .init(rawValue: identifier), title: "Title", branchName: "b",
        state: .init(name: "Todo", type: "unstarted"))
}

@Suite("Status: waiting on you, done autonomously, risks")
struct StatusReviewTests {
    @Test("Done autonomously lists the activity and automatic proposals since --since, oldest first")
    func done() throws {
        let lines = StatusReview.done(try loadState(), since: now.addingTimeInterval(-StatusReview.defaultSince), now: now)
            .joined(separator: "\n")
        #expect(!lines.contains("SPL-1"))
        #expect(lines.contains("agent finished SPL-2"))
        #expect(lines.contains("conflicts resolved on SPL-3: https://github.com/o/r/pull/3"))
        #expect(lines.contains("SPL-4 completed in Linear after its merge"))
        #expect(lines.contains("applied automatically: addRelation → issue SPL-5"))
        let order = ["SPL-2", "SPL-3", "SPL-4", "addRelation"].map { lines.range(of: $0)!.lowerBound }
        #expect(order == order.sorted())
        // A longer --since reaches further back.
        #expect(StatusReview.done(try loadState(), since: now.addingTimeInterval(-7 * 24 * 3600), now: now).joined().contains("agent started on SPL-1"))
    }

    @Test("--since takes a number and a unit")
    func since() {
        #expect(StatusReview.duration("24h") == 24 * 3600 as TimeInterval)
        #expect(StatusReview.duration("7d") == 7 * 24 * 3600 as TimeInterval)
        #expect(StatusReview.duration("90m") == 90 * 60 as TimeInterval)
        #expect(StatusReview.duration("45s") == 45)
        #expect(StatusReview.duration("1.5h") == 5400)
        for text in ["soon", "24", "h", "-1h", "0d", ""] {
            #expect(StatusReview.duration(text) == nil, "\(text)")
        }
    }

    @Test("Waiting on you orders stacks by the work they hold back, bottom first")
    func waitingOnYou() throws {
        let state = try loadState()
        let pullRequests = [
            pullRequest(1, head: "linear/spl-7-name"),
            pullRequest(2, head: "linear/spl-5-database"),
            pullRequest(3, head: "linear/spl-60-on-top", base: "linear/spl-5-database"),
            pullRequest(4, head: "draft", draft: true),
            pullRequest(5, head: "linear/spl-6-spike"),
            pullRequest(20, head: "b20"),
        ]
        let waiting = StatusReview.waitingOnYou(pullRequests, state: state)
        // #2 blocks SPL-41 and SPL-42, with #3 on it: 3. #5 blocks SPL-43: 1.
        // #4 is a draft and #20 has an agent on it.
        #expect(waiting.map(\.pullRequest.number) == [2, 3, 5, 1])
        #expect(waiting.map(\.stackedOn) == [nil, 2, nil, nil])
        #expect(waiting.map(\.blockedIssues) == [["SPL-41", "SPL-42"], [], ["SPL-43"], []])
    }

    @Test("Blocked issues are counted through the issues they block")
    func blockedIssues() throws {
        let blocked = StatusReview.blockedIssues(try loadState().blocked)
        #expect(blocked["SPL-5"] == ["SPL-41", "SPL-42"])
        #expect(blocked["SPL-41"] == ["SPL-42"])
        #expect(blocked["SPL-6"] == ["SPL-43"])
    }

    @Test("The report puts the pull requests in that order, with their stacks and what they block, then the proposals in Linear")
    func rendered() throws {
        let state = try loadState()
        let pullRequests = [
            pullRequest(1, head: "linear/spl-7-name"),
            pullRequest(2, head: "linear/spl-5-database"),
            pullRequest(3, head: "linear/spl-60-on-top", base: "linear/spl-5-database"),
            pullRequest(20, head: "linear/spl-20-review"),
        ]
        let reviews = ReviewEntry.entries(pullRequests: pullRequests, issues: ["SPL-7", "SPL-5", "SPL-60", "SPL-20"].map(issue))
        var busy = state.inFlight["i-r"]!
        busy.review = ReviewRequest(number: 20, url: "https://github.com/o/r/pull/20")
        let report = WorkspaceReport(
            name: "w",
            entries: [TaskEntry(identifier: "SPL-20", title: "Twenty", category: .addressingReview, detail: "queued, https://github.com/o/r/pull/20")],
            reviews: reviews,
            waitingOnYou: StatusReview.waitingOnYou(pullRequests, state: state),
            proposalsWaiting: state.proposals.filter(\.isPosted),
            done: StatusReview.done(state, since: now.addingTimeInterval(-3600 * 6), now: now), since: now.addingTimeInterval(-3600 * 6),
            risks: ["CI failure on main (ci): https://ci/1"],
            warnings: []
        )
        let text = report.rendered(now: now)
        let expected = """
        w
          Waiting on you
            SPL-5   #2 PR 2
                    not reviewed · no CI · blocks 2 issues · https://github.com/o/r/pull/2
            SPL-60  #3 PR 3
                    stacked on #2 · not reviewed · no CI · https://github.com/o/r/pull/3
            SPL-7   #1 PR 1
                    not reviewed · no CI · https://github.com/o/r/pull/1
            SPL-20  #20 PR 20
                    agent addressing review · no CI · https://github.com/o/r/pull/20
            2 proposals waiting in Linear, labeled "superlinear: proposed"
              createIssue on SPL-90: https://linear.app/t/issue/SPL-90
              editIssue on SPL-7: https://linear.app/t/issue/SPL-7#comment-c1
          Addressing review
            SPL-20  Twenty
                    queued, https://github.com/o/r/pull/20
        """
        #expect(text.hasPrefix(expected), "\(text)")
        #expect(text.contains("  Done autonomously since "))
        #expect(text.contains("  conflicts resolved on SPL-3"))
        #expect(text.hasSuffix("  Risks\n    CI failure on main (ci): https://ci/1"))

        let quiet = WorkspaceReport(name: "w", entries: [], done: [], since: now, risks: [], warnings: [])
        #expect(quiet.rendered(now: now).hasSuffix("Done autonomously since \(StatusTime.rendered(now, now: now))\n    Nothing\n  Risks\n    None found"))
        #expect(WorkspaceReport(name: "w", entries: [], warnings: []).rendered() == "w\n  No tasks")
    }

    @Test("The summary counts the proposals in Linear")
    func summary() throws {
        let state = try loadState()
        let report = WorkspaceReport(name: "w", entries: [], proposalsWaiting: state.proposals.filter(\.isPosted), warnings: [])
        #expect(StatusSummary(reports: [report]).counts.map { "\($0.heading) \($0.count)" } == ["Proposals in Linear 2"])
    }

    @Test("Risks list CI failing on the default branch and a low rate limit")
    func risks() {
        let runs = [
            WorkflowRun(headBranch: "feature", status: "completed", startedAt: nil, updatedAt: nil, workflowName: "ci", conclusion: .success),
            WorkflowRun(headBranch: "main", status: "in_progress", startedAt: nil, updatedAt: nil, workflowName: "ci"),
            WorkflowRun(headBranch: "main", status: "completed", startedAt: nil, updatedAt: nil, workflowName: "ci", conclusion: .failure, url: "https://ci/1"),
            WorkflowRun(headBranch: "main", status: "completed", startedAt: nil, updatedAt: nil, workflowName: "ci", conclusion: .success),
        ]
        let latest = StatusReview.latestRun(runs, on: "main")
        #expect(latest?.url == "https://ci/1")
        let noPauses = StatusReview.Pauses(claude: nil, waiting: [], spendingLimit: nil)
        let risks = StatusReview.risks(
            defaultBranch: "main", latestRun: latest,
            rateLimit: StatusReview.RateLimit(remaining: 100, limit: 5000, reset: now.addingTimeInterval(600)),
            pauses: noPauses, now: now
        )
        #expect(risks.count == 2)
        #expect(risks[0] == "CI failure on main (ci): https://ci/1")
        #expect(risks[1].hasPrefix("GitHub rate limit: 100 of 5000 left"))
        #expect(StatusReview.risks(
            defaultBranch: "main", latestRun: runs[3],
            rateLimit: StatusReview.RateLimit(remaining: 4000, limit: 5000, reset: now), pauses: noPauses, now: now
        ).isEmpty)
    }

    @Test("Runs read from gh run list carry their conclusion, which later values do not break")
    func runs() throws {
        let data = Data(#"""
            [{"headBranch": "main", "status": "in_progress", "startedAt": null, "updatedAt": null, "conclusion": "", "url": "u", "workflowName": "ci"},
             {"headBranch": "main", "status": "completed", "startedAt": null, "updatedAt": null, "conclusion": "timed_out"},
             {"headBranch": "main", "status": "completed", "startedAt": null, "updatedAt": null, "conclusion": "brand_new"}]
            """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let runs = try decoder.decode([WorkflowRun].self, from: data)
        #expect(runs.map(\.conclusion) == [nil, .timedOut, nil])
        #expect(StatusReview.risks(
            defaultBranch: "main", latestRun: StatusReview.latestRun(runs, on: "main"), rateLimit: nil,
            pauses: StatusReview.Pauses(claude: nil, waiting: [], spendingLimit: nil), now: now
        ) == ["CI timed_out on main"])
    }

    @Test("The rate limit is read from gh api rate_limit")
    func rateLimit() throws {
        let data = Data(#"{"resources": {"core": {"limit": 5000, "remaining": 1, "reset": 1}, "graphql": {"limit": 5000, "remaining": 42, "reset": 1800000000}}}"#.utf8)
        #expect(try StatusReview.decodeRateLimit(data) == StatusReview.RateLimit(remaining: 42, limit: 5000, reset: now))
    }

    @Test("A finished run becomes the matching activity")
    func activity() {
        var run = AgentRun(issueId: "i", identifier: "SPL-1", branchName: "b", sessionId: "s")
        #expect(ActivityEvent.finished(run, status: 0, time: now).kind == .agentFinished)
        #expect(ActivityEvent.finished(run, status: 1, time: now).kind == .agentFailed)
        #expect(ActivityEvent.finished(run, status: nil, time: now).kind == .agentStopped)
        run.review = ReviewRequest(number: 1, url: "u")
        #expect(ActivityEvent.finished(run, status: 0, time: now) == ActivityEvent(time: now, kind: .reviewAddressed, identifier: "SPL-1", detail: "u"))
    }

    @Test("Activity older than 30 days is dropped")
    func activityRetention() {
        var state = State()
        state.recordActivity(ActivityEvent(time: now.addingTimeInterval(-31 * 24 * 60 * 60), kind: .agentStarted, identifier: "SPL-1"), workspace: "w")
        state.recordActivity(ActivityEvent(time: now, kind: .agentStarted, identifier: "SPL-2"), workspace: "w")
        #expect(state.workspaces["w"]?.activity.map(\.identifier) == ["SPL-2"])
    }

    @Test("Queued runs start oldest first; the Todo order in Linear is the only queue order")
    func queueOrder() {
        func run(_ id: String, queued: TimeInterval, review: Bool = false) -> (String, AgentRun) {
            var run = AgentRun(issueId: id, identifier: .init(rawValue: id), branchName: id, sessionId: id, queuedAt: now.addingTimeInterval(queued))
            if review { run.review = ReviewRequest(number: 1, url: "u") }
            return ("w", run)
        }
        let runs = [run("a", queued: 0), run("b", queued: 1), run("r", queued: -1, review: true)]
        #expect(AgentRunner.nextQueued(runs)?.1.issueId == "r")
        #expect(AgentRunner.nextQueued(Array(runs.prefix(2)))?.1.issueId == "a")
    }

    @Test("The spec document's ID is the slug at the end of its URL")
    func specDocument() {
        #expect(PlanningConfig(specDocumentURL: "https://linear.app/t/document/the-spec-0123abcd").specDocumentId == "0123abcd")
        #expect(PlanningConfig().specDocumentId == nil)
    }
}
