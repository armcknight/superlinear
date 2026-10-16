import Foundation

extension PullRequest {
    static let jsonFields = "number,url,state,headRefName,isDraft,additions,deletions,changedFiles,baseRefName,headRefOid"

    /// The pull request that speaks for `branch`: an open one first, then a
    /// merged one, then a closed one, the newest of each.
    static func best(for branch: String, among pullRequests: [PullRequest]) -> PullRequest? {
        let rank: [State: Int] = [.open: 0, .merged: 1]
        return pullRequests.filter { $0.headRefName == branch }.min { a, b in
            let (rankA, rankB) = (rank[a.state] ?? 2, rank[b.state] ?? 2)
            return rankA == rankB ? a.number > b.number : rankA < rankB
        }
    }

    /// Every pull request in the repository at `repoPath`, from `gh`.
    static func list(in repoPath: String) throws -> [PullRequest] {
        let data = try GitHubCLI.run(["pr", "list", "--state", "all", "--limit", "1000", "--json", jsonFields], in: repoPath)
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
    /// An agent is addressing a review of its pull request, or is queued to.
    case addressingReview
    /// An agent is merging the base branch into its pull request's branch to
    /// resolve their conflicts, or is queued to.
    case resolvingConflicts
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
        case .addressingReview: "Addressing review"
        case .resolvingConflicts: "Resolving conflicts"
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
            // Interrupted, it resumes like any other run.
            if run.review != nil && (running || run.isQueued) { return .addressingReview }
            if run.conflict != nil && (running || run.isQueued) { return .resolvingConflicts }
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
    var branch = ""
    /// The pull request that speaks for the branch, if any.
    var pullRequest: PullRequest? = nil
    /// What the agent's Claude sessions used, if their transcripts were found.
    var usage: AgentUsage? = nil
    /// Time the branch's finished CI runs took, if CI runs were listed.
    var ciTime: TimeInterval? = nil
}

/// What `superlinear status` prints for one workspace.
struct WorkspaceReport: Sendable {
    let name: String
    let entries: [TaskEntry]
    /// Open pull requests belonging to Linear issues, whether or not the
    /// daemon is tracking the issue. Nil when GitHub or Linear could not be
    /// asked, in which case open pull requests show only among the tasks.
    var reviews: [ReviewEntry]? = nil
    /// The agents' open and merged pull requests, for the summary.
    var pullRequestStats: [PullRequestStats] = []
    /// Local branches and worktrees no longer needed.
    var stale: [StaleBranch] = []
    /// Problems that left the report incomplete, such as Linear or GitHub
    /// being out of reach.
    var warnings: [String]

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
                detail: detail(for: category, run: run, issue: issue, pullRequest: pullRequest, runner: runner),
                branch: branch,
                pullRequest: pullRequest
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
        let issueState = issue.map { issue in
            "\(GitHubIssue.number(ofIssueId: issue.id) == nil ? "Linear" : "GitHub"): \(issue.state.name)"
        }
        switch category {
        case .running:
            guard let run else { return nil }
            return "pid \(run.pid ?? 0), log \(runner.agentLog(for: run))"
        case .addressingReview, .resolvingConflicts:
            guard let run, let url = run.review?.url ?? run.conflict?.url else { return nil }
            if run.isQueued {
                let attempt = run.resumes > 0 ? ", to resume, attempt \(run.resumes + 1)" : ""
                return "queued\(attempt), \(url)"
            }
            return "pid \(run.pid ?? 0), log \(runner.agentLog(for: run)), \(url)"
        case .interrupted:
            return "resumes when the daemon next starts"
        case .queued:
            guard let run, run.resumes > 0 else { return nil }
            return "to resume, attempt \(run.resumes + 1)"
        case .openPullRequest:
            guard let pullRequest else { return nil }
            return pullRequest.isDraft == true ? "\(pullRequest.url) (draft)" : pullRequest.url
        case .merged:
            return [pullRequest?.url, issueState].compactMap { $0 }.joined(separator: ", ")
        case .completed:
            return pullRequest?.url
        case .noPullRequest, .closed:
            return [issueState, pullRequest.map { "\($0.url) (closed)" }].compactMap { $0 }.joined(separator: ", ")
        }
    }

    static let staleHeading = "Stale branches and worktrees"

    /// The report as text, one section per category with entries in it.
    func rendered(now: Date = Date()) -> String {
        var lines = [name]
        for warning in warnings {
            lines.append("  warning: \(warning)")
        }
        // Open pull requests are listed for review instead, when they could be.
        let tasks = reviews == nil ? entries : entries.filter { $0.category != .openPullRequest }
        let reviews = reviews ?? []
        if tasks.isEmpty && reviews.isEmpty && stale.isEmpty && warnings.isEmpty {
            lines.append("  No tasks")
        }
        let width = (tasks.map(\.identifier.count) + reviews.map(\.issue.identifier.count)).max() ?? 0
        let indent = String(repeating: " ", count: 4 + width + 2)
        // Their pull requests wait on an agent, not on a reviewer.
        var agentAt: [String: String] = [:]
        for entry in entries {
            switch entry.category {
            case .addressingReview: agentAt[entry.identifier] = "agent addressing review"
            case .resolvingConflicts: agentAt[entry.identifier] = "agent resolving conflicts"
            default: break
            }
        }

        for (heading, drafts) in [("Awaiting review", false), ("Draft pull requests", true)] {
            let section = reviews.filter { $0.pullRequest.isDraft == drafts }
            guard !section.isEmpty else { continue }
            lines.append("  \(heading)")
            for review in section {
                let pullRequest = review.pullRequest
                let padded = review.issue.identifier.padding(toLength: width, withPad: " ", startingAt: 0)
                lines.append("    \(padded)  #\(pullRequest.number) \(pullRequest.title)".trimmingTrailingWhitespace())
                let reviewState = agentAt[review.issue.identifier] ?? pullRequest.reviewState.rawValue
                let state = drafts ? [] : [reviewState]
                let conflicts = pullRequest.mergeable == "CONFLICTING" ? ["conflicts with \(pullRequest.baseRefName ?? "base")"] : []
                lines.append(
                    indent + (state + conflicts + [pullRequest.checkState.rawValue, pullRequest.url]).joined(separator: " · "))
            }
        }

        for category in TaskCategory.allCases {
            let section = tasks.filter { $0.category == category }
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

        if !stale.isEmpty {
            lines.append("  \(Self.staleHeading)")
            for branch in stale {
                lines.append("    \(branch.branch)")
                lines.append("      \(branch.detail(now: now))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Gathers the report for one workspace from the state file, Linear and
    /// GitHub. Never throws: what cannot be fetched becomes a warning.
    static func gather(
        workspace: WorkspaceConfig, state: State, runner: AgentRunner, transcripts: Transcripts
    ) async -> WorkspaceReport {
        let workspaceState = state.workspaces[workspace.name] ?? WorkspaceState()
        var warnings: [String] = []

        var issues: [LinearIssueStatus] = []
        let ids = Array(workspaceState.processedIssueIds.union(workspaceState.inFlight.keys)).sorted()
        let linearIds = ids.filter { GitHubIssue.number(ofIssueId: $0) == nil }
        if !linearIds.isEmpty {
            do {
                issues = try await LinearClient(apiKey: workspace.apiKey).fetchIssues(ids: linearIds)
            } catch {
                warnings.append("Could not fetch issues from Linear: \(error)")
            }
        }
        // GitHub's issues stand in for Linear's, for those the daemon took
        // from GitHub.
        var gitHubIssues: [LinearIssueStatus] = []
        if workspace.githubIssues || linearIds.count < ids.count {
            let repoPath = NSString(string: workspace.repoPath).expandingTildeInPath
            do {
                gitHubIssues = try GitHubIssueClient.allIssues(in: repoPath).map(\.status)
                let processed = Set(ids)
                issues += gitHubIssues.filter { processed.contains($0.id) }
            } catch {
                warnings.append("Could not list GitHub issues: \(error)")
            }
        }

        let repoPath = NSString(string: workspace.repoPath).expandingTildeInPath
        let protected = StaleBranches.protectedBranches(repoPath: repoPath)
        let branches = StaleBranches.localBranches(repoPath: repoPath).filter { !protected.contains($0.name) }

        var pullRequests: [PullRequest]?
        if (!ids.isEmpty && !issues.isEmpty) || !branches.isEmpty {
            do {
                pullRequests = try PullRequest.list(in: repoPath)
            } catch {
                warnings.append("Could not list pull requests, so only agents in flight are shown: \(error)")
            }
        }

        var reviews: [ReviewEntry]?
        do {
            let open = try ReviewablePullRequest.listOpen(in: repoPath)
            let identifiers = Array(Set(open.flatMap(\.issueIdentifiers)))
            let linked = try await LinearClient(apiKey: workspace.apiKey).fetchIssues(identifiers: identifiers)
            reviews = ReviewEntry.entries(pullRequests: open, issues: linked + gitHubIssues)
        } catch {
            warnings.append("Could not list open pull requests for review: \(error)")
        }

        var tasks = entries(state: workspaceState, issues: issues, pullRequests: pullRequests, runner: runner)
        var ciTimes: [String: TimeInterval]?
        if !tasks.isEmpty || reviews?.isEmpty == false {
            do {
                    let runs = try WorkflowRun.list(in: repoPath)
                // A repository without CI has no CI time, rather than none per task.
                if !runs.isEmpty { ciTimes = WorkflowRun.time(byBranch: runs) }
            } catch {
                warnings.append("Could not list CI runs: \(error)")
            }
        }
        for index in tasks.indices {
            tasks[index].usage = transcripts.usage(forBranch: tasks[index].branch)
            if let ciTimes { tasks[index].ciTime = ciTimes[tasks[index].branch] ?? 0 }
        }

        var stats = PullRequestStats.of(tasks: tasks, reviews: reviews ?? []) { branch in
            (transcripts.usage(forBranch: branch), ciTimes.map { $0[branch] ?? 0 })
        }
        // Merged branches are in their base already, so only open ones can
        // be measured locally.
        for index in stats.indices where !stats[index].merged {
            guard let base = stats[index].base,
                let diff = LocalDiff.measure(branch: stats[index].branch, base: base, in: repoPath)
            else { continue }
            stats[index].apply(diff)
        }
        let ahead = stats.filter(\.forkedAheadOfOrigin)
        for base in Set(ahead.compactMap(\.base)).sorted() {
            let count = ahead.filter { $0.base == base }.count
            let commits = LocalDiff.commitsAhead(base: base, in: repoPath).map { " by \($0) commits" } ?? ""
            warnings.append(
                "Local \(base) is ahead of origin/\(base)\(commits), and \(count) open pull request\(count == 1 ? "" : "s") "
                    + "include commits from it, so GitHub shows them larger than they are. Push \(base). "
                    + "The summary measures them from the local fork point.")
        }

        var stale: [StaleBranch] = []
        if let pullRequests {
            stale = StaleBranches.find(
                branches: branches, pullRequests: pullRequests, protected: protected,
                inFlight: Set(workspaceState.inFlight.values.map(\.branchName)),
                worktreesRoot: "\(repoPath)/worktrees"
            )
            stale = StaleBranches.countUnpushed(stale, repoPath: repoPath)
        }

        return WorkspaceReport(
            name: workspace.name,
            entries: tasks,
            reviews: reviews,
            pullRequestStats: stats,
            stale: stale,
            warnings: warnings
        )
    }
}

enum StatusCommand {
    /// A repository whose report hit a GitHub rate limit, to ask GitHub when
    /// it resets; nil when none did.
    static func rateLimitedRepoPath(_ reports: [WorkspaceReport], config: Config) -> String? {
        let workspace = zip(reports, config.workspaces).first { report, _ in
            report.warnings.contains { $0.localizedCaseInsensitiveContains("rate limit") }
        }?.1
        return workspace.map { NSString(string: $0.repoPath).expandingTildeInPath }
    }

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
        let transcripts = Transcripts()

        var reports = await withTaskGroup(of: (Int, WorkspaceReport).self) { group in
            for (index, workspace) in config.workspaces.enumerated() {
                group.addTask { (index, await WorkspaceReport.gather(
                    workspace: workspace, state: state, runner: runner, transcripts: transcripts)) }
            }
            var reports: [(Int, WorkspaceReport)] = []
            for await report in group {
                reports.append(report)
            }
            return reports.sorted { $0.0 < $1.0 }.map(\.1)
        }

        var header: [String] = []
        if let repoPath = rateLimitedRepoPath(reports, config: config) {
            // One line, rather than one per GitHub call in every workspace.
            for index in reports.indices {
                reports[index].warnings.removeAll { $0.localizedCaseInsensitiveContains("rate limit") }
            }
            let reset = GitHubRateLimit.resetDate(repoPath: repoPath)
            let time = reset.formatted(date: .omitted, time: .shortened)
            header.append("warning: GitHub's rate limit is used up until \(time), so pull requests could not all be listed")
        }
        let summary = StatusSummary(reports: reports).rendered()
        let footer = DaemonStatus.read().footer(polls: config.workspaces.map { ($0.name, state.workspaces[$0.name]?.poll) })
        print((header + reports.map { $0.rendered() } + [summary, footer]).joined(separator: "\n\n"))
        return 0
    }
}

/// What `superlinear status` says about the daemon: from the file it writes
/// when it starts, or, for a daemon from before it wrote one, from its lock.
struct DaemonStatus {
    var info: DaemonInfo?
    /// The pid in the lock file, for a daemon that wrote no info file.
    var lockPid: Int32?
    var running: Bool
    var binaryReplaced = false

    static func read(home: String = Paths.home) -> DaemonStatus {
        if let info = DaemonInfo.read(from: DaemonInfo.fileURL(home: home)) {
            let running = info.isRunning
            let current = BinaryWatcher.identity(of: info.executablePath)
            let replaced = running && info.binaryIdentity != nil && current != nil && current != info.binaryIdentity
            return DaemonStatus(info: info, running: running, binaryReplaced: replaced)
        }
        let text = (try? String(contentsOfFile: "\(home)/.local/share/superlinear/daemon.lock", encoding: .utf8)) ?? ""
        let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        let running = pid.map { kill($0, 0) == 0 || errno == EPERM } ?? false
        return DaemonStatus(lockPid: pid, running: running)
    }

    func rendered(now: Date = Date()) -> String {
        if let info { return info.rendered(running: running, binaryReplaced: binaryReplaced, now: now) }
        if running, let lockPid {
            return "Daemon: pid \(lockPid), started before daemons recorded their version; restart it to see more"
        }
        return "Daemon: not running"
    }

    /// The end of the report: this command's build, the daemon's, and each
    /// workspace's polls, in config order. Each workspace polls on its own
    /// loop, so each has its own times.
    func footer(polls: [(name: String, poll: PollRecord?)], now: Date = Date()) -> String {
        var lines = [Self.statusLine(), rendered(now: now)]
        guard !polls.isEmpty else { return lines.joined(separator: "\n") }
        lines.append("Polls")
        let width = polls.map(\.name.count).max() ?? 0
        for (name, poll) in polls {
            let padded = name.padding(toLength: width, withPad: " ", startingAt: 0)
            lines.append("  \(padded)  \(poll?.rendered(daemonRunning: running, now: now) ?? "not polled yet")")
        }
        return lines.joined(separator: "\n")
    }

    /// The version and binary of this `superlinear status`.
    static func statusLine() -> String {
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return "superlinear \(Superlinear.fullVersion) at \(path)"
    }
}

extension String {
    func trimmingTrailingWhitespace() -> String {
        var text = self
        while text.last?.isWhitespace == true {
            text.removeLast()
        }
        return text
    }
}
