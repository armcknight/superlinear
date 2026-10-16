import Foundation
import Testing
@testable import superlinear

private let hour: TimeInterval = 60 * 60
private let day: TimeInterval = 24 * hour
/// Noon, so a day's arithmetic stays in the same day in any time zone.
private let now = StandupSession.dayFormatter.date(from: "2026-10-16")!.addingTimeInterval(12 * hour)
private let history = ForecastHistory(agentTime: 1 * hour, startToMerge: 4 * hour, count: 10)

private func date(_ text: String) -> Date { StandupSession.dayFormatter.date(from: text)! }

private func issue(_ id: String, blockers: [String] = [], startedAt: Date? = nil) -> ForecastIssue {
    ForecastIssue(
        id: LinearIssue.ID(rawValue: id), identifier: LinearIssue.Identifier(rawValue: id),
        blockers: blockers.map(LinearIssue.ID.init(rawValue:)), startedAt: startedAt)
}

private func sample(_ identifier: String, mergedDaysAgo: Double, agentHours: Double?, startToMergeHours: Double?) -> CompletedIssueSample {
    CompletedIssueSample(
        identifier: LinearIssue.Identifier(rawValue: identifier), mergedAt: now.addingTimeInterval(-mergedDaysAgo * day),
        agentTime: agentHours.map { $0 * hour }, startToMerge: startToMergeHours.map { $0 * hour })
}

private let beta = ProjectIssue.Milestone(id: "m-beta", name: "Beta", targetDate: "2026-10-17", sortOrder: 1)
private let ga = ProjectIssue.Milestone(id: "m-ga", name: "GA", targetDate: nil, sortOrder: 2)
private let alpha = ProjectIssue.Milestone(id: "m-alpha", name: "Alpha", targetDate: "2026-10-10", sortOrder: 0)
private let app = ProjectIssue.Project(id: "p-app", name: "App")
private let site = ProjectIssue.Project(id: "p-site", name: "Site")

private func projectIssue(
    _ identifier: String, project: ProjectIssue.Project = app, milestone: ProjectIssue.Milestone? = nil,
    state: LinearStateType = .unstarted, priority: Double = 0, sortOrder: Double = 0, startedAt: Date? = nil,
    completedAt: Date? = nil, blockedBy: [(String, String)] = []
) -> ProjectIssue {
    ProjectIssue(
        id: LinearIssue.ID(rawValue: "id-\(identifier)"), identifier: LinearIssue.Identifier(rawValue: identifier),
        title: "Title \(identifier)", branchName: "branch-\(identifier.lowercased())", priority: priority,
        sortOrder: sortOrder, startedAt: startedAt, completedAt: completedAt, state: .init(type: state),
        project: project, projectMilestone: milestone,
        inverseRelations: .init(nodes: blockedBy.map { blocker, type in
            .init(type: "blocks", issue: .init(
                id: LinearIssue.ID(rawValue: "id-\(blocker)"), identifier: LinearIssue.Identifier(rawValue: blocker),
                state: .init(type: type)))
        }))
}

private func merged(_ number: Int, branch: String, daysAgo: Double) -> PullRequest {
    PullRequest(
        number: PullRequest.Number(rawValue: number), url: "https://github.com/o/r/pull/\(number)", state: .merged,
        headRefName: branch, mergedAt: now.addingTimeInterval(-daysAgo * day))
}

@Suite("Forecast")
struct ForecastTests {
    @Test("The history takes the medians of the last 30 issues merged, each measure over the issues that have it")
    func historyMedians() throws {
        // 30 recent issues: agent times 1h to 30h, start to merge 10h to 300h.
        var samples = (1...30).map {
            sample("SPL-\($0)", mergedDaysAgo: Double($0), agentHours: Double($0), startToMergeHours: Double($0 * 10))
        }
        // Older ones do not count.
        samples += (31...40).map { sample("SPL-\($0)", mergedDaysAgo: Double($0), agentHours: 1000, startToMergeHours: 1000) }
        // An issue without transcripts still counts for start to merge.
        samples[0].agentTime = nil
        let history = try #require(ForecastHistory.of(samples))
        #expect(history.count == 30)
        #expect(history.agentTime == 16 * hour)
        #expect(history.startToMerge == 155 * hour)
    }

    @Test("No history without an agent time or a start-to-merge time")
    func noHistory() {
        #expect(ForecastHistory.of([]) == nil)
        #expect(ForecastHistory.of([sample("SPL-1", mergedDaysAgo: 1, agentHours: nil, startToMergeHours: 3)]) == nil)
        #expect(ForecastHistory.of([sample("SPL-1", mergedDaysAgo: 1, agentHours: 3, startToMergeHours: nil)]) == nil)
    }

    @Test("Samples are the completed issues with a merged pull request, timed from their start")
    func samples() {
        let issues = [
            LinearIssueStatus(id: "1", identifier: "SPL-1", title: "", branchName: "b1", state: .init(name: "Done", type: "completed"),
                              startedAt: now.addingTimeInterval(-3 * day)),
            LinearIssueStatus(id: "2", identifier: "SPL-2", title: "", branchName: "b2", state: .init(name: "Done", type: "completed")),
            LinearIssueStatus(id: "3", identifier: "SPL-3", title: "", branchName: "b3", state: .init(name: "Todo", type: "unstarted")),
            LinearIssueStatus(id: "4", identifier: "SPL-4", title: "", branchName: "b4", state: .init(name: "Done", type: "completed")),
        ]
        let pullRequests = [
            merged(1, branch: "b1", daysAgo: 1), merged(2, branch: "b2", daysAgo: 2), merged(3, branch: "b3", daysAgo: 1),
            PullRequest(number: 4, url: "u4", state: .closed, headRefName: "b4"),
        ]
        let samples = ProjectUpdates.samples(issues: issues, pullRequests: pullRequests) { $0 == "b1" ? 2 * hour : nil }
        #expect(samples == [
            CompletedIssueSample(identifier: "SPL-1", mergedAt: now.addingTimeInterval(-day), agentTime: 2 * hour, startToMerge: 2 * day),
            CompletedIssueSample(identifier: "SPL-2", mergedAt: now.addingTimeInterval(-2 * day), agentTime: nil, startToMerge: nil),
        ])
    }

    @Test("The schedule keeps to the agent limit and the dependency order")
    func schedule() {
        let issues = [
            issue("A"), issue("B"), issue("C", blockers: ["A"]), issue("D"), issue("E", blockers: ["C", "B"]),
            // Started an hour ago: its agent is done, and it merges 3 hours from now.
            issue("S", startedAt: now.addingTimeInterval(-hour)),
        ]
        let merges = Forecast.schedule(issues, history: history, agents: 2, now: now)
        let hours = merges.mapValues { $0.timeIntervalSince(now) / hour }
        #expect(hours == ["A": 4, "B": 4, "D": 5, "C": 8, "E": 12, "S": 3])

        // One agent runs them one after another.
        let serial = Forecast.schedule(Array(issues.prefix(5)), history: history, agents: 1, now: now)
        #expect(serial.mapValues { $0.timeIntervalSince(now) / hour } == ["A": 4, "B": 5, "D": 6, "C": 8, "E": 12])
    }

    @Test("A started issue keeps an agent until its median agent time is up")
    func startedKeepsAgent() {
        let issues = [issue("S", startedAt: now.addingTimeInterval(-hour / 2)), issue("A")]
        let merges = Forecast.schedule(issues, history: history, agents: 1, now: now)
        #expect(merges.mapValues { $0.timeIntervalSince(now) / hour } == ["S": 3.5, "A": 4.5])
    }

    @Test("Blockers outside the schedule are left out, and a cycle still gets scheduled")
    func outsideBlockersAndCycles() {
        let issues = [issue("A", blockers: ["elsewhere"]), issue("P", blockers: ["Q"]), issue("Q", blockers: ["P"])]
        let merges = Forecast.schedule(issues, history: history, agents: 3, now: now)
        #expect(merges.mapValues { $0.timeIntervalSince(now) / hour } == ["A": 4, "P": 4, "Q": 8])
    }

    @Test("Health is off track past the target date, at risk when forecast after it, and absent without one")
    func health() {
        let target = date("2026-10-17")
        let forecast = { (hours: Double) in now.addingTimeInterval(hours * hour) }
        #expect(Forecast.health(targetDate: target, openIssues: 2, forecast: forecast(4), now: now) == .onTrack)
        // The target day ends at midnight after it, 36 hours from noon the day before.
        #expect(Forecast.health(targetDate: target, openIssues: 2, forecast: forecast(35), now: now) == .onTrack)
        #expect(Forecast.health(targetDate: target, openIssues: 2, forecast: forecast(37), now: now) == .atRisk)
        #expect(Forecast.health(targetDate: date("2026-10-15"), openIssues: 2, forecast: forecast(1), now: now) == .offTrack)
        #expect(Forecast.health(targetDate: date("2026-10-15"), openIssues: 0, forecast: nil, now: now) == .onTrack)
        #expect(Forecast.health(targetDate: nil, openIssues: 2, forecast: forecast(1), now: now) == nil)
        #expect(Forecast.health(targetDate: target, openIssues: 2, forecast: nil, now: now) == nil)
    }

    /// App: Alpha is past its target with one issue open; Beta has a chain
    /// of three; GA has no target. Site has one issue in Beta of its own.
    private var fixture: [ProjectIssue] {
        [
            projectIssue("APP-1", milestone: alpha, priority: 1),
            projectIssue("APP-2", milestone: beta, sortOrder: 1),
            projectIssue("APP-3", milestone: beta, sortOrder: 2, blockedBy: [("APP-2", "unstarted")]),
            projectIssue("APP-4", milestone: beta, sortOrder: 3, blockedBy: [("APP-3", "unstarted")]),
            projectIssue("APP-5", milestone: ga),
            projectIssue("APP-6", milestone: beta, state: .completed, completedAt: now.addingTimeInterval(-day)),
            projectIssue("APP-7", state: .completed, completedAt: now.addingTimeInterval(-2 * day)),
            projectIssue("SITE-1", project: site, milestone: ProjectIssue.Milestone(
                id: "m-site", name: "Launch", targetDate: "2026-10-30", sortOrder: 1)),
        ]
    }

    @Test("Milestones get their last open issue's merge, scheduled across the workspace's projects")
    func milestones() {
        let milestones = ProjectUpdates.milestones(fixture, history: history, agents: 2, now: now)
        #expect(milestones.map(\.name) == ["Alpha", "Beta", "GA", "Launch"])
        let hours = milestones.map { $0.forecast.map { $0.timeIntervalSince(now) / hour } }
        // APP-1 is urgent, then by milestone and sort order: SITE-1 and
        // APP-2 go before APP-5, and APP-3 and APP-4 wait on APP-2's merge.
        #expect(hours == [4, 13, 5, 4])
        #expect(milestones.map(\.openIssues) == [1, 3, 1, 1])
        #expect(milestones.map(\.health) == [.offTrack, .onTrack, nil, .onTrack])

        // With one agent, Beta ends after its target.
        let slow = ProjectUpdates.milestones(fixture, history: ForecastHistory(agentTime: 6 * hour, startToMerge: 12 * hour, count: 3),
                                             agents: 1, now: now)
        #expect(slow[1].health == .atRisk)
        #expect(ProjectUpdates.risks(slow) == [
            "Milestone App › Alpha: target 2026-10-10 passed with 1 open issue",
            "Milestone App › Beta: forecast 2026-10-18, after its target 2026-10-17",
        ])
        #expect(Standup.risks(defaultBranch: nil, latestRun: nil, rateLimit: nil, milestones: slow) == ProjectUpdates.risks(slow))
    }

    @Test("Without a history there is no forecast, but past targets are still off track")
    func milestonesWithoutHistory() {
        let milestones = ProjectUpdates.milestones(fixture, history: nil, agents: 2, now: now)
        #expect(milestones.allSatisfy { $0.forecast == nil })
        #expect(milestones.map(\.health) == [.offTrack, nil, nil, nil])
    }

    @Test("A project's update lists what happened, the milestones and where the forecast comes from")
    func body() throws {
        let since = now.addingTimeInterval(-7 * day)
        let decision = StandupDecision(time: now, identifier: "APP-1", text: "Ship without dark mode")
        let milestones = ProjectUpdates.milestones(fixture, history: history, agents: 2, now: now)
        let reports = ProjectUpdates.reports(
            issues: fixture,
            pullRequests: [merged(12, branch: "branch-app-6", daysAgo: 1), merged(9, branch: "branch-app-6", daysAgo: 30),
                           merged(13, branch: "other", daysAgo: 1)],
            decisions: [decision, StandupDecision(time: now, identifier: "OTHER-1", text: "x")],
            needsHuman: ["id-APP-5": WaitingIssue(identifier: "APP-5", title: "Pick a name", labels: ["Needs human"])],
            milestones: milestones, since: since)
        #expect(reports.map(\.projectName) == ["App", "Site"])
        let app = reports[0]
        #expect(app.completed == ["APP-6", "APP-7"])
        #expect(app.merged.map(\.number) == [12])
        #expect(app.decisions == [decision])
        #expect(app.needsHuman.map(\.identifier) == ["APP-5"])
        #expect(app.health == .offTrack)
        #expect(!reports[1].hasActivity)

        #expect(ProjectUpdates.body(app, history: history, agents: 2, since: since) == """
            Since 2026-10-09: 2 issues completed, 1 pull request merged.

            - Completed: APP-6, APP-7
            - Merged: [#12](https://github.com/o/r/pull/12)
            - Decision on APP-1: Ship without dark mode
            - Needs human: APP-5

            Milestones:
            - Alpha: 1 open, forecast 2026-10-16, target 2026-10-10, off track
            - Beta: 3 open, forecast 2026-10-17, target 2026-10-17, on track
            - GA: 1 open, forecast 2026-10-16, no target date

            Forecast from the last 10 completed issues: median agent time 1h 00m, median start to merge 4h 00m, at most 2 agents at once.
            """)
        var site = reports[1]
        site.milestones = ProjectUpdates.milestones(fixture, history: nil, agents: 1, now: now)
            .filter { $0.projectId == site.projectId }
        #expect(ProjectUpdates.body(site, history: nil, agents: 1, since: since) == """
            Since 2026-10-09: 0 issues completed, 0 pull requests merged.

            Milestones:
            - Launch: 1 open, target 2026-10-30

            No forecast: no completed issue has both an agent time and a start-to-merge time yet.
            """)

        let drafts = ProjectUpdates.drafts(reports, history: history, agents: 2, since: since, now: now)
        #expect(drafts.count == 1)
        let draft = try #require(drafts.first)
        #expect(draft.target == .project("p-app", name: "App"))
        #expect(draft.source == ProposalSource(kind: .standup, value: "2026-10-16"))
        guard case .postProjectUpdate(let body, let health) = draft.payload else {
            Issue.record("Not a project update: \(draft.payload)")
            return
        }
        #expect(health == .offTrack)
        #expect(body == ProjectUpdates.body(app, history: history, agents: 2, since: since))
    }

    @Test("Project updates with different text are different proposals")
    func sameness() {
        let a = ProposalPayload.postProjectUpdate(body: "One", health: nil)
        let b = ProposalPayload.postProjectUpdate(body: "Two", health: .onTrack)
        #expect(Proposal.sameness(a, .project("p")) != Proposal.sameness(b, .project("p")))
        #expect(Proposal.sameness(a, .project("p")) == Proposal.sameness(a, .project("p")))
    }

    @Test("Project updates stored before health was added load without one")
    func olderPayload() throws {
        let payload = try JSONDecoder().decode(ProposalPayload.self, from: Data(#"{"postProjectUpdate":{"body":"Hi"}}"#.utf8))
        #expect(payload == .postProjectUpdate(body: "Hi", health: nil))
    }
}

/// Linear for project updates: records what is posted.
private actor UpdateLinear: LinearWriting {
    var posted: [String] = []
    var fails = false

    init(fails: Bool = false) { self.fails = fails }

    func editableIssue(id: LinearIssue.ID) async throws -> EditableIssue { throw LinearClientError.invalidResponse }
    func openIssues(like title: String, teamId: LinearTeam.ID) async throws -> [IssueMatch] { [] }
    func labelId(named name: String, teamId: LinearTeam.ID) async throws -> LinearLabel.ID { "label" }
    func createIssue(
        teamId: LinearTeam.ID, projectId: LinearProject.ID?, title: String, description: String, labelIds: [LinearLabel.ID]
    ) async throws -> JSONValue { throw LinearClientError.invalidResponse }
    func updateIssueDescription(id: LinearIssue.ID, description: String) async throws -> JSONValue { throw LinearClientError.invalidResponse }
    func closeIssue(id: LinearIssue.ID) async throws -> JSONValue { throw LinearClientError.invalidResponse }
    func promoteIssue(id: LinearIssue.ID) async throws -> JSONValue { throw LinearClientError.invalidResponse }
    func createRelation(issueId: LinearIssue.ID, relatedIssueId: LinearIssue.ID, type: String) async throws -> JSONValue {
        throw LinearClientError.invalidResponse
    }
    func spec(of target: ProposalTarget) async throws -> SpecText { throw LinearClientError.invalidResponse }
    func updateSpec(of target: ProposalTarget, content: String) async throws -> JSONValue { throw LinearClientError.invalidResponse }

    func postProjectUpdate(projectId: LinearProject.ID, body: String, health: ProjectHealth?) async throws -> JSONValue {
        if fails { throw LinearClientError.apiError(["Not allowed"]) }
        posted.append("\(projectId) \(health?.rawValue ?? "none")\n\(body)")
        return .object(["success": .bool(true)])
    }
}

@Suite("Project updates after a standup")
struct ProjectUpdateProposalTests {
    private let since = now.addingTimeInterval(-7 * day)

    private func forecast(_ issues: [ProjectIssue]) -> ProjectForecast {
        ProjectForecast(history: history, agents: 2, issues: [], refetch: { issues })
    }

    private func engine(_ linear: UpdateLinear, level: TrustLevel) -> ProposalEngine {
        let audit = AuditLog(directory: FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID())"))
        return ProposalEngine(workspace: "w", autonomy: Autonomy(overrides: [.postProjectUpdate: level]), linear: linear, audit: audit)
    }

    private let issues = [
        projectIssue("APP-1", milestone: beta),
        projectIssue("APP-2", milestone: beta, state: .completed, completedAt: now.addingTimeInterval(-day)),
        projectIssue("SITE-1", project: site),
    ]

    @Test("By default an update waits for the next standup, one per project with activity")
    func standupLevel() async {
        let linear = UpdateLinear()
        let made = await forecast(issues).proposeUpdates(
            engine: engine(linear, level: .standup), existing: [], decisions: [], needsHuman: [:], since: since, now: now)
        #expect(made.proposals.map(\.target) == [.project("p-app", name: "App")])
        #expect(made.proposals.map(\.status) == [.pending])
        #expect(made.proposals.map(\.trust) == [.standup])
        #expect(made.summary == ["Proposed an update for App, for the next standup"])
        #expect(await linear.posted.isEmpty)
    }

    @Test("An auto update is posted at once with its health and source")
    func autoLevel() async throws {
        let linear = UpdateLinear()
        let made = await forecast(issues).proposeUpdates(
            engine: engine(linear, level: .auto), existing: [], decisions: [], needsHuman: [:], since: since, now: now)
        #expect(made.proposals.map(\.status) == [.applied])
        #expect(made.summary == ["Posted an update for App"])
        let posted = try #require(await linear.posted.first)
        #expect(posted.hasPrefix("p-app onTrack\nSince 2026-10-09: 1 issue completed, 0 pull requests merged."))
        #expect(posted.hasSuffix("\n\nSource: standup of 2026-10-16"))
    }

    @Test("A failed post stays pending, an update rejected before is not made again, and never makes none")
    func failuresAndRepeats() async {
        let failing = await forecast(issues).proposeUpdates(
            engine: engine(UpdateLinear(fails: true), level: .auto), existing: [], decisions: [], needsHuman: [:],
            since: since, now: now)
        #expect(failing.proposals.map(\.status) == [.pending])
        #expect(failing.summary.first?.hasPrefix("Could not post an update for App") == true)

        var rejected = failing.proposals[0]
        rejected.status = .rejected
        let again = await forecast(issues).proposeUpdates(
            engine: engine(UpdateLinear(), level: .auto), existing: [rejected], decisions: [], needsHuman: [:],
            since: since, now: now)
        #expect(again.proposals.isEmpty)
        #expect(again.summary == ["No update for App: The same postProjectUpdate was rejected before"])

        let never = await forecast(issues).proposeUpdates(
            engine: engine(UpdateLinear(), level: .never), existing: [], decisions: [], needsHuman: [:], since: since, now: now)
        #expect(never.proposals.isEmpty)
    }

    @Test("The daemon takes in a standup's new proposals once, and not those older than the record keeps")
    func takeIn() {
        let draft = ProposalDraft(
            payload: .postProjectUpdate(body: "Hi", health: nil), target: .project("p"), reason: "r",
            source: ProposalSource(kind: .standup, value: "2026-10-16"))
        let fresh = Proposal(draft, trust: .standup, id: "fresh", now: now)
        let old = Proposal(draft, trust: .standup, id: "old", now: now.addingTimeInterval(-40 * day))
        var standup = WorkspaceStandup()
        standup.newProposals = [fresh, old]

        var state = State()
        state.takeIn(standup, workspace: "w", now: now)
        state.takeIn(standup, workspace: "w", now: now)
        #expect(state.proposals(workspace: "w").map(\.id) == ["fresh"])

        standup.prune(now: now)
        #expect(standup.newProposals.map(\.id) == ["fresh"])
    }

    @Test("The standup record keeps new proposals, and older records have none")
    func record() throws {
        let draft = ProposalDraft(
            payload: .postProjectUpdate(body: "Hi", health: .atRisk), target: .project("p"), reason: "r",
            source: ProposalSource(kind: .standup, value: "2026-10-16"))
        var record = StandupRecord()
        record["w"].newProposals = [Proposal(draft, trust: .auto, id: "x", now: now)]
        #expect(try StandupRecord.decoded(from: record.encoded()) == record)
        #expect(try StandupRecord.decoded(from: Data(#"{"workspaces":{"w":{}}}"#.utf8))["w"].newProposals.isEmpty)
    }
}
