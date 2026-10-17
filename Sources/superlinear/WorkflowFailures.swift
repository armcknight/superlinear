import Foundation

/// Failing CI on the default branch, proposed as one new issue per workflow,
/// however many of its runs fail: the title is the same for each, so a
/// pending proposal or the open issue it made stops the next.
enum WorkflowFailures {
    static let failedConclusions: Set<WorkflowRun.Conclusion> = [.failure, .timedOut, .startupFailure]

    static func listArguments(branch: String) -> [String] {
        [
            "gh", "run", "list", "--branch", branch, "--limit", "100",
            "--json", "headBranch,workflowName,status,conclusion,url,headSha,createdAt",
        ]
    }

    static func decodeRuns(_ data: Data) throws -> [WorkflowRun] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([WorkflowRun].self, from: data)
    }

    /// The latest completed run of each workflow whose latest completed run
    /// failed, by workflow name. A workflow fixed since it failed has none.
    static func failing(_ runs: [WorkflowRun]) -> [WorkflowRun] {
        let completed = runs.filter { $0.status == "completed" && $0.workflowName != nil && $0.url != nil }
        let latest = Dictionary(grouping: completed) { $0.workflowName ?? "" }
            .compactMap { $0.value.max { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) } }
        return latest
            .filter { $0.conclusion.map(failedConclusions.contains) ?? false }
            .sorted { ($0.workflowName ?? "") < ($1.workflowName ?? "") }
    }

    /// Whether the run is one of those the spending limit stopped, by the
    /// run ID that ends its URL.
    static func isStopped(_ run: WorkflowRun, stopped: Set<WorkflowRun.ID>) -> Bool {
        guard let id = run.url.flatMap({ URL(string: $0)?.lastPathComponent }).flatMap(Int.init) else { return false }
        return stopped.contains(WorkflowRun.ID(rawValue: id))
    }

    static func title(workflow: String, branch: String) -> String {
        "CI fails on \(branch): \(workflow)"
    }

    /// The proposal for a run `failing` returned, which has a name and URL.
    static func draft(_ run: WorkflowRun, branch: String, teamId: LinearTeam.ID) -> ProposalDraft {
        let workflow = run.workflowName ?? "unnamed"
        let url = run.url ?? ""
        let description = """
            The latest run of the \(workflow) workflow on `\(branch)` ended in \
            `\(run.conclusion?.rawValue ?? "failure")` at commit \(run.headSha?.prefix(12) ?? "unknown"): \(url)
            """
        return ProposalDraft(
            payload: .createIssue(
                teamId: teamId, projectId: nil, title: title(workflow: workflow, branch: branch),
                description: description, relatedIssueId: nil
            ),
            target: .team(teamId),
            reason: "The \(workflow) workflow fails on \(branch)",
            source: ProposalSource(kind: .workflowRun, value: url)
        )
    }
}
