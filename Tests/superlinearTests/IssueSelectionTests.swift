import Foundation
import Testing
@testable import superlinear

// Selection decides which issues get agents. An agent started too early works
// on an issue whose groundwork is not merged, or on one meant for a person.
@Suite("Issue selection")
struct IssueSelectionTests {
    private func workspace(_ extra: String = "") throws -> WorkspaceConfig {
        let json = #"{"workspaces": [{"name": "w", "apiKey": "k", "repoPath": "~/r"\#(extra)}]}"#
        return try #require(try Config.decoded(from: Data(json.utf8)).workspaces.first)
    }

    private func issue(
        _ identifier: String, created: TimeInterval = 0, stateType: String = "unstarted",
        priority: Double? = nil, project: Double? = nil, milestone: Double? = nil, sortOrder: Double? = nil,
        labels: [String] = [], blockers: [(String, String)] = []
    ) -> LinearIssue {
        LinearIssue(
            id: "id-\(identifier)", identifier: identifier, title: "Title \(identifier)", branchName: "b-\(identifier)",
            createdAt: Date(timeIntervalSince1970: created), team: .init(id: "t", key: "SL"),
            state: .init(name: stateType, type: stateType),
            priority: priority, sortOrder: sortOrder,
            project: project.map { .init(sortOrder: $0) }, projectMilestone: milestone.map { .init(sortOrder: $0) },
            labels: .init(nodes: labels.map { .init(name: $0) }),
            inverseRelations: .init(nodes: blockers.map { identifier, state in
                .init(type: "blocks", issue: .init(id: "id-\(identifier)", identifier: identifier, state: .init(type: state)))
            })
        )
    }

    // MARK: Blockers

    @Test("An issue with an open blocker waits, and starts once its last blocker is completed")
    func blockedIssueWaitsThenStarts() throws {
        let workspace = try workspace()
        let waiting = IssueSelection.plan(
            [issue("SL-2", blockers: [("SL-1", "started"), ("SL-0", "completed")])], workspace: workspace, handled: [])
        #expect(waiting.start.isEmpty)
        #expect(waiting.blocked["id-SL-2"] == WaitingIssue(identifier: "SL-2", title: "Title SL-2", blockers: ["SL-1"]))

        let unblocked = IssueSelection.plan(
            [issue("SL-2", blockers: [("SL-1", "completed"), ("SL-0", "completed")])], workspace: workspace, handled: [])
        #expect(unblocked.start.map(\.identifier) == ["SL-2"])
        #expect(unblocked.blocked.isEmpty)
    }

    @Test("A canceled blocker no longer blocks, and only blocks relations count")
    func onlyOpenBlocksRelationsBlock() throws {
        var related = issue("SL-3")
        related.inverseRelations = .init(nodes: [
            .init(type: "related", issue: .init(id: "id-SL-1", identifier: "SL-1", state: .init(type: "started"))),
        ])
        let plan = IssueSelection.plan(
            [issue("SL-2", blockers: [("SL-1", "canceled")]), related], workspace: try workspace(), handled: [])
        #expect(plan.start.map(\.identifier) == ["SL-2", "SL-3"])
    }

    // MARK: Human labels

    @Test("An issue with a human label never starts, even with no blockers, whatever the label's case")
    func humanLabelNeverStarts() throws {
        let plan = IssueSelection.plan(
            [issue("SL-1", labels: ["Feature", "spike"]), issue("SL-2", labels: ["Needs human"], blockers: [("SL-9", "started")])],
            workspace: try workspace(), handled: []
        )
        #expect(plan.start.isEmpty)
        #expect(plan.needsHuman["id-SL-1"]?.labels == ["spike"])
        // The label wins: no blocker's completion can start it.
        #expect(plan.needsHuman["id-SL-2"] != nil)
        #expect(plan.blocked.isEmpty)
    }

    @Test("humanLabels replaces the default labels")
    func configuredHumanLabels() throws {
        let plan = IssueSelection.plan(
            [issue("SL-1", labels: ["Spike"]), issue("SL-2", labels: ["Design"])],
            workspace: try workspace(#", "humanLabels": ["Design"]"#), handled: []
        )
        #expect(plan.start.map(\.identifier) == ["SL-1"])
        #expect(plan.needsHuman.keys.sorted() == ["id-SL-2"])
    }

    // MARK: What drops out

    @Test("Issues already handled, or no longer in a startable state, neither start nor wait")
    func handledAndMovedIssuesDropOut() throws {
        let plan = IssueSelection.plan(
            [issue("SL-1", blockers: [("SL-9", "started")]), issue("SL-2", stateType: "started", labels: ["Spike"]),
             issue("SL-3"), issue("SL-3")],
            workspace: try workspace(), handled: ["id-SL-1"]
        )
        #expect(plan.start.map(\.identifier) == ["SL-3"])
        #expect(plan.blocked.isEmpty)
        #expect(plan.needsHuman.isEmpty)
    }

    // MARK: Order

    @Test("New mode starts the oldest issue first")
    func newModeOrder() throws {
        let plan = IssueSelection.plan(
            [issue("SL-2", created: 20, priority: 1), issue("SL-1", created: 10, priority: 4)],
            workspace: try workspace(), handled: []
        )
        #expect(plan.start.map(\.identifier) == ["SL-1", "SL-2"])
    }

    @Test("Ready mode orders by priority, no priority last, then project, milestone and sort order, ignoring creation dates")
    func readyModeOrder() throws {
        let issues = [
            issue("SL-1", created: 1, priority: 0),
            issue("SL-2", created: 2, priority: 3, project: 2),
            issue("SL-3", created: 3, priority: 3, project: 1, milestone: 5),
            issue("SL-4", created: 4, priority: 3, project: 1, milestone: 2, sortOrder: 9),
            issue("SL-5", created: 5, priority: 3, project: 1, milestone: 2, sortOrder: -1),
            issue("SL-6", created: 6, priority: 1),
            issue("SL-7", created: 7, priority: 3),
        ]
        let plan = IssueSelection.plan(issues.reversed(), workspace: try workspace(#", "selection": "ready""#), handled: [])
        #expect(plan.start.map(\.identifier) == ["SL-6", "SL-5", "SL-4", "SL-3", "SL-2", "SL-7", "SL-1"])
    }

    @Test("Ready mode starts from the ready states only")
    func readyStates() throws {
        let issues = [issue("SL-1", stateType: "backlog"), issue("SL-2", stateType: "unstarted")]
        let byDefault = IssueSelection.plan(issues, workspace: try workspace(#", "selection": "ready""#), handled: [])
        #expect(byDefault.start.map(\.identifier) == ["SL-2"])
        let configured = IssueSelection.plan(
            issues, workspace: try workspace(#", "selection": "ready", "readyStates": ["backlog"]"#), handled: [])
        #expect(configured.start.map(\.identifier) == ["SL-1"])
    }

    // MARK: First poll

    @Test("A workspace's first poll in new mode fetches no issues created before it")
    func firstPollStartsNothingOld() async throws {
        let candidates = try await WorkspaceProcessor.newCandidates(
            lastPoll: .distantPast, waiting: [],
            created: { _ in Issue.record("The first poll fetched created issues"); return [] },
            byIds: { _ in [] }
        )
        #expect(candidates.isEmpty)
    }

    @Test("Later polls fetch issues created since the last, then the waiting issues not among them")
    func laterPollsRecheckWaitingIssues() async throws {
        let lastPoll = Date(timeIntervalSince1970: 100)
        let fresh = issue("SL-2")
        let candidates = try await WorkspaceProcessor.newCandidates(
            lastPoll: lastPoll, waiting: ["id-SL-1", "id-SL-2"],
            created: { since in
                #expect(since == lastPoll)
                return [fresh]
            },
            byIds: { ids in
                #expect(ids == ["id-SL-1"])
                return [issue("SL-1")]
            }
        )
        #expect(candidates.map(\.identifier) == ["SL-2", "SL-1"])
    }
}
