import Foundation
import Testing
@testable import superlinear

/// Linear as the standup sees it, kept in memory, recording every write.
private actor FakeLinear: StandupWriting {
    var issues: [LinearIssue.ID: EditableIssue] = [:]
    var specs: [String: SpecText] = [:]
    var writes: [String] = []

    init(issues: [EditableIssue] = [], specs: [String: SpecText] = [:]) {
        self.issues = Dictionary(uniqueKeysWithValues: issues.map { ($0.id, $0) })
        self.specs = specs
    }

    private func written(_ description: String) -> JSONValue {
        writes.append(description)
        return .object(["success": .bool(true)])
    }

    func editableIssue(id: LinearIssue.ID) async throws -> EditableIssue {
        guard let issue = issues[id] else { throw LinearClientError.apiError(["Entity not found"]) }
        return issue
    }

    func openIssues(like title: String, teamId: LinearTeam.ID) async throws -> [IssueMatch] { [] }
    func labelId(named name: String, teamId: LinearTeam.ID) async throws -> LinearLabel.ID { "label" }

    func createIssue(
        teamId: LinearTeam.ID, projectId: LinearProject.ID?, title: String, description: String, labelIds: [LinearLabel.ID]
    ) async throws -> JSONValue {
        written("create \(title)")
    }

    func updateIssueDescription(id: LinearIssue.ID, description: String) async throws -> JSONValue {
        issues[id]?.description = description
        return written("edit \(id)")
    }

    func closeIssue(id: LinearIssue.ID) async throws -> JSONValue { written("close \(id)") }
    func promoteIssue(id: LinearIssue.ID) async throws -> JSONValue { written("promote \(id)") }

    func createRelation(issueId: LinearIssue.ID, relatedIssueId: LinearIssue.ID, type: String) async throws -> JSONValue {
        written("relate \(issueId) \(type) \(relatedIssueId)")
    }

    func spec(of target: ProposalTarget) async throws -> SpecText {
        guard let spec = specs[target.rawID] else { throw LinearClientError.apiError(["Entity not found"]) }
        return spec
    }

    func updateSpec(of target: ProposalTarget, content: String) async throws -> JSONValue {
        specs[target.rawID]?.content = content
        return written("spec \(target.rawID)")
    }

    func postProjectUpdate(projectId: LinearProject.ID, body: String, health: ProjectHealth?) async throws -> JSONValue {
        written("update \(projectId)")
    }

    func completeIssue(id: LinearIssue.ID) async throws -> Bool {
        writes.append("done \(id)")
        return true
    }
}

/// The owner, as a script of answers.
private final class ScriptedIO: StandupIO, @unchecked Sendable {
    var answers: [String]
    var edits: [String]
    var output: [String] = []

    init(_ answers: [String], edits: [String] = []) {
        self.answers = answers
        self.edits = edits
    }

    func say(_ text: String) { output.append(text) }

    func ask(_ prompt: String) -> String? {
        output.append(prompt)
        return answers.isEmpty ? nil : answers.removeFirst()
    }

    func edit(_ text: String) -> String? {
        edits.isEmpty ? nil : edits.removeFirst()
    }

    var text: String { output.joined(separator: "\n") }
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let lastStandup = now.addingTimeInterval(-24 * 60 * 60)

/// A state file as the daemon writes it: activity before and after the last
/// standup, an automatic proposal and two waiting on the owner, a chain of
/// blocked issues behind two that need a human, a queued run, and a review run.
private let stateFile = """
{"workspaces": {"w": {
  "processedIssueIds": ["i-q1", "i-q2", "i-r"],
  "lastPollTimestamp": "2027-01-15T07:00:00Z",
  "inFlight": {
    "i-q1": {"issueId": "i-q1", "identifier": "SPL-31", "branchName": "b31", "sessionId": "s1",
             "resumes": 0, "queuedAt": "2027-01-15T07:00:00Z"},
    "i-q2": {"issueId": "i-q2", "identifier": "SPL-32", "branchName": "b32", "sessionId": "s2",
             "resumes": 0, "queuedAt": "2027-01-15T07:00:01Z"},
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
    "i-h6": {"identifier": "SPL-6", "title": "Spike the sync", "blockers": [], "labels": ["Spike"]},
    "i-h7": {"identifier": "SPL-7", "title": "Pick a name", "blockers": [], "labels": ["Needs human"]}
  },
  "proposals": [
    {"id": "auto-1", "payload": {"addRelation": {"relatedIssueId": "i-b1", "type": "related"}},
     "target": {"kind": "issue", "id": "i-h5", "name": "SPL-5"}, "reason": "they touch the same code",
     "source": {"kind": "pullRequest", "value": "https://github.com/o/r/pull/9"},
     "createdAt": "2027-01-15T05:00:00Z", "status": "applied", "trust": "auto", "decidedAt": "2027-01-15T05:00:00Z"},
    {"id": "edit-1", "payload": {"editIssue": {"oldText": "Old plan", "newText": "New plan"}},
     "target": {"kind": "issue", "id": "i-h7", "name": "SPL-7"}, "reason": "the plan changed",
     "source": {"kind": "agentSession", "value": "abc"},
     "createdAt": "2027-01-15T04:00:00Z", "status": "pending", "trust": "standup", "targetUpdatedAt": "2027-01-15T03:00:00Z"},
    {"id": "close-1", "payload": {"closeIssue": {}},
     "target": {"kind": "issue", "id": "i-h6", "name": "SPL-6"}, "reason": "the spike is moot",
     "source": {"kind": "commitRange", "value": "a..b"},
     "createdAt": "2027-01-15T04:30:00Z", "status": "pending", "trust": "standup", "targetUpdatedAt": "2027-01-15T03:00:00Z"}
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

private func lastRecord() -> WorkspaceStandup {
    var standup = WorkspaceStandup()
    standup.lastStandupAt = lastStandup
    standup.unblocked = ["SPL-30"]
    return standup
}

private func upcoming(_ identifier: LinearIssue.Identifier, id: String) -> LinearIssue {
    LinearIssue(
        id: LinearIssue.ID(rawValue: id), identifier: identifier, title: "Ready \(identifier)", branchName: id,
        createdAt: now, team: .init(id: "t", key: "SPL")
    )
}

private func view(_ standup: WorkspaceStandup = lastRecord()) throws -> StandupView {
    var view = StandupView(
        workspace: "w", state: try loadState(), standup: standup,
        upcoming: [upcoming("SPL-33", id: "i-u3"), upcoming("SPL-34", id: "i-u4")], now: now
    )
    view.backlog = [PlanItem(issueId: "i-bl", identifier: "SPL-50", title: "Someday")]
    return view
}

private func pullRequest(_ number: PullRequest.Number, head: String, base: String = "main", draft: Bool = false) -> ReviewablePullRequest {
    ReviewablePullRequest(
        number: number, url: "https://github.com/o/r/pull/\(number)", title: "PR \(number)", headRefName: head,
        isDraft: draft, reviewDecision: nil, latestReviews: nil, statusCheckRollup: nil, baseRefName: base
    )
}

private func editable(_ id: String, identifier: String, description: String = "") -> EditableIssue {
    EditableIssue(
        id: LinearIssue.ID(rawValue: id), identifier: identifier, description: description,
        updatedAt: Date(timeIntervalSince1970: 1_799_982_000), labels: [], stateType: .unstarted, teamId: "t"
    )
}

private func applier(_ linear: FakeLinear, specDocument: LinearDocument.ID? = nil) -> StandupApplier {
    let audit = AuditLog(directory: FileManager.default.temporaryDirectory.appendingPathComponent("superlinear-\(UUID().uuidString)"))
    return StandupApplier(
        engine: ProposalEngine(workspace: "w", autonomy: Autonomy(), linear: linear, audit: audit),
        linear: linear, specDocument: specDocument
    )
}

@Suite("Standup sections")
struct StandupSectionTests {
    @Test("Done autonomously lists the activity and automatic proposals since the last standup")
    func done() throws {
        let lines = try view().rendered(section: .done).joined(separator: "\n")
        #expect(!lines.contains("SPL-1"))
        #expect(lines.contains("agent finished SPL-2"))
        #expect(lines.contains("conflicts resolved on SPL-3: https://github.com/o/r/pull/3"))
        #expect(lines.contains("SPL-4 completed in Linear after its merge"))
        #expect(lines.contains("applied automatically: addRelation → issue SPL-5"))
        // Oldest first.
        let order = ["SPL-2", "SPL-3", "SPL-4", "addRelation"].map { lines.range(of: $0)!.lowerBound }
        #expect(order == order.sorted())
    }

    @Test("The first standup looks back 7 days")
    func firstStandup() throws {
        let view = try view(WorkspaceStandup())
        #expect(view.since == now.addingTimeInterval(-7 * 24 * 60 * 60))
        #expect(view.rendered(section: .done).joined().contains("agent started on SPL-1"))
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
        let waiting = Standup.waitingOnYou(pullRequests, state: state)
        // #2 blocks SPL-41 and SPL-42, with #3 on it: 3. #5 blocks SPL-43: 1.
        // #4 is a draft and #20 has an agent on it.
        #expect(waiting.map(\.pullRequest.number) == [2, 3, 5, 1])
        #expect(waiting.map(\.stackedOn) == [nil, 2, nil, nil])
        #expect(waiting.map(\.blockedIssues) == [["SPL-41", "SPL-42"], [], ["SPL-43"], []])
        var view = try view()
        view.waitingOnYou = waiting
        let text = view.rendered(section: .waitingOnYou).joined(separator: "\n")
        #expect(text.contains("#3 PR 3"))
        #expect(text.contains("stacked on #2"))
        #expect(text.contains("blocks 2 issues"))
    }

    @Test("Proposals lists those pending, with reason, source and diff")
    func proposals() throws {
        let text = try view().rendered(section: .proposals).joined(separator: "\n")
        #expect(text.contains("editIssue → issue SPL-7"))
        #expect(text.contains("reason: the plan changed"))
        #expect(text.contains("source: agent session abc"))
        #expect(text.contains("- Old plan"))
        #expect(text.contains("+ New plan"))
        #expect(text.contains("closeIssue → issue SPL-6"))
        #expect(!text.contains("addRelation"))
    }

    @Test("Needs human sorts by the open issues blocked, directly and indirectly")
    func needsHuman() throws {
        let view = try view()
        #expect(view.needsHuman.map(\.issue.identifier) == ["SPL-5", "SPL-6", "SPL-7"])
        #expect(view.needsHuman.map(\.blockedIssues) == [["SPL-41", "SPL-42"], ["SPL-43"], []])
        #expect(view.rendered(section: .needsHuman).joined(separator: "\n").contains("SPL-5  Choose a database  [Needs human · blocks 2]"))
    }

    @Test("The plan lists the queue, then the ready issues, in the standup's order, holds apart")
    func plan() throws {
        var standup = lastRecord()
        standup.order = ["i-u4"]
        standup.held = ["i-q2": "SPL-32", "i-gone": "SPL-99"]
        let view = try view(standup)
        #expect(view.plan.map(\.identifier) == ["SPL-34", "SPL-31", "SPL-33"])
        #expect(view.held.map(\.identifier) == ["SPL-32", "SPL-99"])
        let text = view.rendered(section: .plan).joined(separator: "\n")
        #expect(text.contains("1. SPL-34  Ready SPL-34"))
        #expect(text.contains("2. SPL-31  (queued)"))
        #expect(text.contains("Unblocked at the last standup: SPL-30"))
    }

    @Test("Risks list CI failing on the default branch and a low rate limit")
    func risks() {
        let failing = Standup.DefaultBranchRun(status: .completed, conclusion: .failure, url: "https://ci/1", workflowName: "ci")
        let risks = Standup.risks(
            defaultBranch: "main", latestRun: failing,
            rateLimit: Standup.RateLimit(remaining: 100, limit: 5000, reset: now.addingTimeInterval(600)), now: now
        )
        #expect(risks.count == 2)
        #expect(risks[0] == "CI failure on main (ci): https://ci/1")
        #expect(risks[1].hasPrefix("GitHub rate limit: 100 of 5000 left"))
        let passing = Standup.DefaultBranchRun(status: .completed, conclusion: .success)
        #expect(Standup.risks(
            defaultBranch: "main", latestRun: passing,
            rateLimit: Standup.RateLimit(remaining: 4000, limit: 5000, reset: now), now: now
        ).isEmpty)
    }

    @Test("A run is read from gh run list, values GitHub adds later included")
    func defaultBranchRun() throws {
        let data = Data(#"""
            [{"status": "in_progress", "conclusion": "", "url": "u", "workflowName": "ci"},
             {"status": "completed", "conclusion": "timed_out"},
             {"status": "brand_new", "conclusion": "brand_new"}]
            """#.utf8)
        let runs = try JSONDecoder().decode([Standup.DefaultBranchRun].self, from: data)
        #expect(runs == [
            Standup.DefaultBranchRun(status: .inProgress, url: "u", workflowName: "ci"),
            Standup.DefaultBranchRun(status: .completed, conclusion: .timedOut),
            Standup.DefaultBranchRun(status: .unknown, conclusion: .unknown),
        ])
        #expect(Standup.risks(defaultBranch: "main", latestRun: runs[1], rateLimit: nil) == ["CI timed_out on main"])
    }

    @Test("The rate limit is read from gh api rate_limit")
    func rateLimit() throws {
        let data = Data(#"{"resources": {"core": {"limit": 5000, "remaining": 1, "reset": 1}, "graphql": {"limit": 5000, "remaining": 42, "reset": 1800000000}}}"#.utf8)
        #expect(try StandupCommand.decodeRateLimit(data) == Standup.RateLimit(remaining: 42, limit: 5000, reset: now))
    }

    @Test("--print shows sections 1, 3, 4 and 5")
    func printed() throws {
        let text = try view().rendered(sections: StandupView.printedSections)
        for heading in ["1. Done autonomously", "3. Proposals", "4. Needs human", "5. Plan for today"] {
            #expect(text.contains(heading))
        }
        #expect(!text.contains("2. Waiting on you"))
        #expect(!text.contains("6. Risks"))
    }

    @Test("Status shows the last standup and what waits for one")
    func statusLine() throws {
        let state = try State.decoded(from: Data(stateFile.utf8))
        var record = StandupRecord()
        #expect(Standup.statusLine(state: state, standups: record, workspaces: ["w"], now: now)
            == "Standup: none yet · 2 pending proposals · 3 need a human")
        record["w"] = lastRecord()
        #expect(Standup.statusLine(state: state, standups: record, workspaces: ["w"], now: now).contains("ago"))
    }
}

@Suite("Standup actions")
struct StandupActionTests {
    /// Runs a standup with `answers` and applies it.
    private func standup(
        _ answers: [String], edits: [String] = [], linear: FakeLinear, specDocument: LinearDocument.ID? = nil,
        record: WorkspaceStandup = lastRecord()
    ) async throws -> (WorkspaceStandup, [String], ScriptedIO) {
        let io = ScriptedIO(answers, edits: edits)
        let session = try StandupPrompter(io: io).run(try view(record), standup: record)
        let outcome = await applier(linear, specDocument: specDocument)
            .apply(session, state: try loadState(), standup: record, now: now)
        return (outcome.standup, outcome.summary, io)
    }

    private func linear() -> FakeLinear {
        FakeLinear(issues: [
            editable("i-h7", identifier: "SPL-7", description: "Mine\n\n<!-- superlinear -->\nOld plan\n<!-- /superlinear -->"),
            editable("i-h6", identifier: "SPL-6"),
            editable("i-h5", identifier: "SPL-5", description: "Which one?"),
        ])
    }

    @Test("Approve applies the proposal at the end, and the state takes in the outcome")
    func approve() async throws {
        let linear = linear()
        let (record, summary, _) = try await standup(["a", "d"], linear: linear)
        #expect(await linear.writes == ["edit i-h7"])
        #expect(await linear.issues["i-h7"]?.description.contains("New plan") == true)
        #expect(summary.contains("Applied editIssue → issue SPL-7"))
        #expect(record.proposalOutcomes.map(\.id) == ["edit-1"])
        #expect(record.lastStandupAt == now)

        var state = try State.decoded(from: Data(stateFile.utf8))
        state.takeIn(record, workspace: "w")
        let byId = Dictionary(uniqueKeysWithValues: state.proposals(workspace: "w").map { ($0.id, $0) })
        #expect(byId["edit-1"]?.status == .applied)
        #expect(byId["close-1"]?.status == .pending)
        #expect(byId["close-1"]?.firstShownAt == now)
    }

    @Test("Edit opens the payload, and the edited change is what is approved")
    func edit() async throws {
        let linear = linear()
        let edited = #"{"editIssue": {"oldText": "Old plan", "newText": "Better plan"}}"#
        let (_, _, io) = try await standup(["e", "a", "d"], edits: [edited], linear: linear)
        #expect(io.text.contains("+ Better plan"))
        #expect(await linear.issues["i-h7"]?.description.contains("Better plan") == true)
    }

    @Test("An edit that changes the kind, or is not JSON, is refused")
    func badEdit() throws {
        let state = try loadState()
        let proposal = try #require(state.proposals.first { $0.id == "edit-1" })
        #expect(throws: StandupError.self) { try StandupSession.edited(proposal, text: #"{"closeIssue": {}}"#) }
        #expect(throws: StandupError.self) { try StandupSession.edited(proposal, text: "nope") }
        let text = try StandupSession.editable(proposal.payload)
        #expect(try StandupSession.edited(proposal, text: text) == proposal)
    }

    @Test("Reject asks for a reason and stores it; defer leaves the proposal pending")
    func rejectAndDefer() async throws {
        let linear = linear()
        let (record, summary, _) = try await standup(["r", "not now", "d"], linear: linear)
        #expect(await linear.writes.isEmpty)
        let rejected = try #require(record.proposalOutcomes.first)
        #expect(rejected.id == "edit-1")
        #expect(rejected.status == .rejected)
        #expect(rejected.rejectionReason == "not now")
        #expect(summary.contains("Deferred 1 proposal"))
        // Both were shown, so both count toward expiry from now.
        #expect(record.proposalsShownAt == ["edit-1": now, "close-1": now])
    }

    @Test("Mark done completes the issue, and the issues it blocked are recorded as unblocked")
    func markDone() async throws {
        let linear = linear()
        // Defer both proposals, then mark SPL-5 done and skip the rest.
        let (record, summary, _) = try await standup(["d", "d", "d", "", ""], linear: linear)
        #expect(await linear.writes == ["done i-h5"])
        #expect(summary.contains("Marked SPL-5 done"))
        #expect(record.unblocked == ["SPL-41"])
    }

    @Test("A decision goes in the issue's managed block and the spec document")
    func decision() async throws {
        let linear = FakeLinear(
            issues: [editable("i-h5", identifier: "SPL-5", description: "Which one?")],
            specs: ["spec": SpecText(content: "# Spec", updatedAt: now)]
        )
        let (record, _, _) = try await standup(["d", "d", "e", "Postgres", "", "", ""], linear: linear, specDocument: "spec")
        let description = try #require(await linear.issues["i-h5"]?.description)
        #expect(description.hasPrefix("Which one?\n\n<!-- superlinear -->\nDecision, "))
        #expect(description.contains(": Postgres\n<!-- /superlinear -->"))
        #expect(await linear.specs["spec"]?.content.hasPrefix("# Spec\n\n- ") == true)
        #expect(await linear.specs["spec"]?.content.hasSuffix(" SPL-5: Postgres") == true)
        #expect(record.decisions.map(\.text) == ["Postgres"])
    }

    @Test("An unknown key asks again")
    func unknownKey() async throws {
        let linear = linear()
        let (_, _, io) = try await standup(["x", "d", "d", "t", "", "", ""], linear: linear)
        #expect(io.text.contains("Type a, e, r, d or q"))
        #expect(io.text.contains("Type d, e, s or q"))
        #expect(await linear.writes.isEmpty)
    }

    @Test("Hold, move and promote change the plan as recorded")
    func planKeys() async throws {
        let linear = linear()
        // Plan: 1 SPL-31, 2 SPL-32, 3 SPL-33, 4 SPL-34; backlog b1 SPL-50.
        let answers = ["d", "d", "", "", "", "h 2", "u 4", "d 1", "p b1", "x", "u 9", ""]
        let (record, summary, io) = try await standup(answers, linear: linear)
        #expect(record.held == ["i-q2": "SPL-32"])
        #expect(record.order == ["i-q2", "i-q1", "i-u4", "i-u3"])
        #expect(await linear.writes == ["promote i-bl"])
        #expect(summary.contains("Holding SPL-32"))
        #expect(summary.contains("Promoted SPL-50 to Todo"))
        #expect(io.text.contains("No item 9"))
        #expect(io.text.contains("SPL-32  (queued)  [held]"))
    }

    @Test("Hold on a held issue releases it")
    func release() async throws {
        var record = lastRecord()
        record.held = ["i-q1": "SPL-31"]
        let (updated, summary, _) = try await standup(["d", "d", "", "", "", "h 4", ""], linear: linear(), record: record)
        #expect(updated.held.isEmpty)
        #expect(summary.contains("Released SPL-31"))
    }

    @Test("Quit leaves everything as it was")
    func quit() throws {
        let io = ScriptedIO(["a", "q"])
        #expect(throws: StandupAborted.self) {
            try StandupPrompter(io: io).run(try view(), standup: lastRecord())
        }
    }
}

@Suite("Standup bookkeeping")
struct StandupBookkeepingTests {
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

    @Test("A standup's order moves fresh runs ahead; others keep their turn")
    func queueOrder() {
        func run(_ id: String, queued: TimeInterval, review: Bool = false) -> (String, AgentRun) {
            var run = AgentRun(issueId: id, identifier: .init(rawValue: id), branchName: id, sessionId: id, queuedAt: now.addingTimeInterval(queued))
            if review { run.review = ReviewRequest(number: 1, url: "u") }
            return ("w", run)
        }
        let runs = [run("a", queued: 0), run("b", queued: 1), run("r", queued: -1, review: true)]
        #expect(AgentRunner.nextQueued(runs)?.1.issueId == "r")
        let order = ["b", "r"]
        #expect(AgentRunner.nextQueued(runs, rank: { order.firstIndex(of: $1.issueId) })?.1.issueId == "b")
    }

    @Test("The standup file round-trips, and an old one without fields reads")
    func record() throws {
        var record = StandupRecord()
        record["w"] = lastRecord()
        record["w"].held = ["i": "SPL-1"]
        #expect(try StandupRecord.decoded(from: record.encoded()) == record)
        #expect(try StandupRecord.decoded(from: Data(#"{"workspaces": {"w": {}}}"#.utf8))["w"] == WorkspaceStandup())
    }

    @Test("The spec document's ID is the slug at the end of its URL")
    func specDocument() {
        #expect(PlanningConfig(specDocumentURL: "https://linear.app/t/document/the-spec-0123abcd").specDocumentId == "0123abcd")
        #expect(PlanningConfig().specDocumentId == nil)
    }

    @Test("standup parses its options")
    func arguments() {
        #expect(Command.parse(["standup"]) == .standup(configPath: nil, workspace: nil, printOnly: false))
        #expect(Command.parse(["standup", "--print", "--workspace", "w", "--config", "c"])
            == .standup(configPath: "c", workspace: "w", printOnly: true))
        #expect(Command.parse(["standup", "--now"]) == .invalid("unknown option for standup: --now"))
    }
}
