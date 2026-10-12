import Foundation

extension PullRequest {
    static let jsonFields = "number,url,state,headRefName,isDraft"

    /// The pull request that speaks for `branch`: an open one first, then a
    /// merged one, then a closed one, the newest of each.
    static func best(for branch: String, among pullRequests: [PullRequest]) -> PullRequest? {
        let rank: [State: Int] = [.open: 0, .merged: 1]
        return pullRequests.filter { $0.headRefName == branch }.min { a, b in
            let (rankA, rankB) = (rank[a.state] ?? 2, rank[b.state] ?? 2)
            return rankA == rankB ? a.number > b.number : rankA < rankB
        }
    }

    /// Every pull request in the repository at `repoPath`, from `gh`, which
    /// works out the GitHub repository from the checkout's remotes.
    static func list(in repoPath: String) throws -> [PullRequest] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gh", "pr", "list", "--state", "all", "--limit", "1000", "--json", jsonFields]
        process.currentDirectoryURL = URL(fileURLWithPath: repoPath)
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Read before waiting, or a full pipe would stall gh forever.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw StatusError.gitHub(text.isEmpty ? "gh exited \(process.terminationStatus)" : text)
        }
        return try JSONDecoder().decode([PullRequest].self, from: data)
    }
}

enum StatusError: Error, CustomStringConvertible {
    case gitHub(String)

    var description: String {
        switch self {
        case .gitHub(let message): message
        }
    }
}

/// Where a task stands. A task is complete only once its pull request is
/// merged and its Linear issue is done; anything short of both is still
/// listed as needing something.
enum TaskCategory: Int, CaseIterable, Comparable, Sendable {
    /// An agent is working on it now.
    case running
    /// Its agent stopped without finishing, as at a reboot. The daemon resumes
    /// it when it next starts.
    case interrupted
    /// Waiting for a free agent slot.
    case queued
    /// The agent finished and its pull request is open.
    case openPullRequest
    /// The pull request is merged, but the Linear issue is not done.
    case merged
    /// The agent finished, but no pull request is open or merged and the issue
    /// is still open.
    case noPullRequest
    /// The pull request is merged and the Linear issue is done.
    case completed
    /// The issue was closed in Linear without a merged pull request.
    case closed

    static func < (a: TaskCategory, b: TaskCategory) -> Bool { a.rawValue < b.rawValue }

    var heading: String {
        switch self {
        case .running: "Running"
        case .interrupted: "Interrupted"
        case .queued: "Queued"
        case .openPullRequest: "Open pull requests"
        case .merged: "Merged, issue not done"
        case .noPullRequest: "Finished without a pull request"
        case .completed: "Completed"
        case .closed: "Closed without a merge"
        }
    }

    /// `run` is the issue's record in the state file, if it is still in
    /// flight; `running` whether that run's process is alive.
    static func of(
        run: AgentRun?, running: Bool, issue: LinearIssueStatus?, pullRequest: PullRequest?
    ) -> TaskCategory {
        if let run {
            if run.isQueued { return .queued }
            return running ? .running : .interrupted
        }
        switch pullRequest?.state {
        case .open: return .openPullRequest
        case .merged: return issue?.isCompleted == true ? .completed : .merged
        default: return issue?.isClosed == true ? .closed : .noPullRequest
        }
    }
}

/// One line of the status report.
struct TaskEntry: Sendable, Equatable {
    let identifier: String
    let title: String
    let category: TaskCategory
    /// A pull request URL, log path, or Linear state, as suits the category.
    let detail: String?
}

/// What `superlinear status` prints for one workspace.
struct WorkspaceReport: Sendable {
    let name: String
    let entries: [TaskEntry]
    /// Problems that left the report incomplete, such as Linear or GitHub
    /// being out of reach.
    let warnings: [String]

    /// Puts each processed issue in a category. Issues Linear no longer
    /// returns, as when archived, are left out unless still in flight. When
    /// the pull requests are unknown, only runs in flight are listed, since
    /// any other issue's category depends on its pull request.
    static func entries(
        state: WorkspaceState,
        issues: [LinearIssueStatus],
        pullRequests: [PullRequest]?,
        runner: AgentRunner,
        isRunning: (AgentRun) -> Bool = AgentRunner.isRunning
    ) -> [TaskEntry] {
        let issuesById = Dictionary(issues.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ids = state.processedIssueIds.union(state.inFlight.keys)

        let entries: [TaskEntry] = ids.compactMap { id in
            let issue = issuesById[id]
            let run = state.inFlight[id]
            guard run != nil || (issue != nil && pullRequests != nil) else { return nil }

            let branch = issue?.branchName ?? run?.branchName ?? ""
            let pullRequest = pullRequests.flatMap { PullRequest.best(for: branch, among: $0) }
            let running = run.map(isRunning) ?? false
            let category = TaskCategory.of(run: run, running: running, issue: issue, pullRequest: pullRequest)

            return TaskEntry(
                identifier: issue?.identifier ?? run?.identifier ?? id,
                title: issue?.title ?? "",
                category: category,
                detail: detail(for: category, run: run, issue: issue, pullRequest: pullRequest, runner: runner)
            )
        }
        return entries.sorted { a, b in
            a.category == b.category
                ? a.identifier.localizedStandardCompare(b.identifier) == .orderedAscending
                : a.category < b.category
        }
    }

    private static func detail(
        for category: TaskCategory, run: AgentRun?, issue: LinearIssueStatus?,
        pullRequest: PullRequest?, runner: AgentRunner
    ) -> String? {
        let linearState = issue.map { "Linear: \($0.state.name)" }
        switch category {
        case .running:
            guard let run else { return nil }
            return "pid \(run.pid ?? 0), log \(runner.agentLog(for: run))"
        case .interrupted:
            return "resumes when the daemon next starts"
        case .queued:
            guard let run, run.resumes > 0 else { return nil }
            return "to resume, attempt \(run.resumes + 1)"
        case .openPullRequest:
            guard let pullRequest else { return nil }
            return pullRequest.isDraft == true ? "\(pullRequest.url) (draft)" : pullRequest.url
        case .merged:
            return [pullRequest?.url, linearState].compactMap { $0 }.joined(separator: ", ")
        case .completed:
            return pullRequest?.url
        case .noPullRequest, .closed:
            return [linearState, pullRequest.map { "\($0.url) (closed)" }].compactMap { $0 }.joined(separator: ", ")
        }
    }

    /// The report as text, one section per category with entries in it.
    func rendered() -> String {
        var lines = [name]
        for warning in warnings {
            lines.append("  warning: \(warning)")
        }
        if entries.isEmpty && warnings.isEmpty {
            lines.append("  No tasks")
        }
        let width = entries.map(\.identifier.count).max() ?? 0
        let indent = String(repeating: " ", count: 4 + width + 2)
        for category in TaskCategory.allCases {
            let section = entries.filter { $0.category == category }
            guard !section.isEmpty else { continue }
            lines.append("  \(category.heading)")
            for entry in section {
                let padded = entry.identifier.padding(toLength: width, withPad: " ", startingAt: 0)
                lines.append("    \(padded)  \(entry.title)".trimmingTrailingWhitespace())
                if let detail = entry.detail, !detail.isEmpty {
                    lines.append(indent + detail)
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Gathers the report for one workspace from the state file, Linear and
    /// GitHub. Never throws: what cannot be fetched becomes a warning.
    static func gather(workspace: WorkspaceConfig, state: State, runner: AgentRunner) async -> WorkspaceReport {
        let workspaceState = state.workspaces[workspace.name] ?? WorkspaceState()
        var warnings: [String] = []

        var issues: [LinearIssueStatus] = []
        let ids = Array(workspaceState.processedIssueIds.union(workspaceState.inFlight.keys)).sorted()
        if !ids.isEmpty {
            do {
                issues = try await LinearClient(apiKey: workspace.apiKey).fetchIssues(ids: ids)
            } catch {
                warnings.append("Could not fetch issues from Linear: \(error)")
            }
        }

        var pullRequests: [PullRequest]?
        if !ids.isEmpty && !issues.isEmpty {
            let repoPath = NSString(string: workspace.repoPath).expandingTildeInPath
            do {
                pullRequests = try PullRequest.list(in: repoPath)
            } catch {
                warnings.append("Could not list pull requests, so only agents in flight are shown: \(error)")
            }
        }

        return WorkspaceReport(
            name: workspace.name,
            entries: entries(state: workspaceState, issues: issues, pullRequests: pullRequests, runner: runner),
            warnings: warnings
        )
    }
}

enum StatusCommand {
    /// Prints a report for every configured workspace, in config order, and
    /// returns the exit status.
    static func run(configPath: String?) async -> Int32 {
        let config: Config
        do {
            config = try Config.load(from: configPath)
        } catch {
            print("[superlinear] Failed to load config: \(error)")
            return 1
        }
        let state = State.load()
        let runner = AgentRunner()

        let reports = await withTaskGroup(of: (Int, WorkspaceReport).self) { group in
            for (index, workspace) in config.workspaces.enumerated() {
                group.addTask { (index, await WorkspaceReport.gather(workspace: workspace, state: state, runner: runner)) }
            }
            var reports: [(Int, WorkspaceReport)] = []
            for await report in group {
                reports.append(report)
            }
            return reports.sorted { $0.0 < $1.0 }.map(\.1)
        }

        print(reports.map { $0.rendered() }.joined(separator: "\n\n"))
        return 0
    }
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        var text = self
        while text.last?.isWhitespace == true {
            text.removeLast()
        }
        return text
    }
}
