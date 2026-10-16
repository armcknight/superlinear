import Foundation

/// Which of a poll's candidate issues get agents, which wait, and in what
/// order the rest start. Every source of issues goes through here, so the
/// rules hold whichever mode or source found them.
struct IssueSelectionPlan: Equatable {
    /// Issues to queue, in the order they should start.
    var start: [LinearIssue] = []
    /// Issues waiting on open blockers, keyed by issue ID.
    var blocked: [LinearIssue.ID: WaitingIssue] = [:]
    /// Issues carrying a human label, keyed by issue ID.
    var needsHuman: [LinearIssue.ID: WaitingIssue] = [:]
}

extension IssueSelection {
    /// Sorts `candidates` for `workspace`. Issues in `handled`, which the
    /// daemon has processed or is running, and issues no longer in a state an
    /// agent may start from are left out, so they stop waiting. A human label
    /// wins over open blockers.
    static func plan(
        _ candidates: [LinearIssue], workspace: WorkspaceConfig, handled: Set<LinearIssue.ID>
    ) -> IssueSelectionPlan {
        var plan = IssueSelectionPlan()
        var seen: Set<LinearIssue.ID> = []
        let startable = workspace.startableStates
        let humanLabels = Set(workspace.humanLabels.map { $0.lowercased() })
        for issue in candidates where seen.insert(issue.id).inserted && !handled.contains(issue.id) {
            if let state = issue.state, LinearStateType(rawValue: state.type).map(startable.contains) != true {
                continue
            }
            let labels = issue.labelNames.filter { humanLabels.contains($0.lowercased()) }
            if !labels.isEmpty {
                plan.needsHuman[issue.id] = WaitingIssue(issue, labels: labels)
                continue
            }
            let blockers = issue.openBlockers
            if !blockers.isEmpty {
                plan.blocked[issue.id] = WaitingIssue(issue, blockers: blockers)
                continue
            }
            plan.start.append(issue)
        }
        plan.start.sort(by: workspace.selection == .ready ? readyOrder : { $0.createdAt < $1.createdAt })
        return plan
    }

    /// Urgent first and no priority last, then by project, milestone and
    /// issue sort order, as Linear orders them. Issues outside a project or
    /// milestone come after those in one.
    static func readyOrder(_ a: LinearIssue, _ b: LinearIssue) -> Bool {
        func rank(_ issue: LinearIssue) -> [Double] {
            let priority = issue.priority.flatMap { $0 > 0 ? $0 : nil } ?? .infinity
            return [
                priority,
                issue.project?.sortOrder ?? .infinity,
                issue.projectMilestone?.sortOrder ?? .infinity,
                issue.sortOrder ?? .infinity,
                issue.createdAt.timeIntervalSinceReferenceDate,
            ]
        }
        let (rankA, rankB) = (rank(a), rank(b))
        guard rankA != rankB else { return a.identifier.localizedStandardCompare(b.identifier) == .orderedAscending }
        return rankA.lexicographicallyPrecedes(rankB)
    }
}
