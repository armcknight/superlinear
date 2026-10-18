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
    /// Waiting for the issues blocking it to be completed or canceled.
    case blocked
    /// A human label keeps agents off it.
    case needsHuman
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
        case .blocked: "Blocked"
        case .needsHuman: "Needs human"
        case .openPullRequest: "Open pull requests"
        case .merged: "Merged, issue not done"
        case .noPullRequest: "Finished without a pull request"
        case .completed: "Completed"
        case .closed: "Closed without a merge"
        }
    }

    /// The name `--status` knows the category by.
    var name: String {
        switch self {
        case .running: "running"
        case .addressingReview: "addressing-review"
        case .resolvingConflicts: "resolving-conflicts"
        case .interrupted: "interrupted"
        case .queued: "queued"
        case .blocked: "blocked"
        case .needsHuman: "needs-human"
        case .openPullRequest: "open-pull-requests"
        case .merged: "merged"
        case .noPullRequest: "no-pull-request"
        case .completed: "completed"
        case .closed: "closed"
        }
    }

    /// `run` is the issue's record in the state file, if it is still in
    /// flight; `running` whether that run's process is alive; `pending` its
    /// merge watch, if its agent has ended.
    static func of(
        run: AgentRun?, running: Bool, issue: LinearIssueStatus?, pullRequest: PullRequest?, pending: PendingMerge?
    ) -> TaskCategory {
        if let run {
            // Interrupted, it resumes like any other run.
            if run.review != nil && (running || run.isQueued) { return .addressingReview }
            if run.conflict != nil && (running || run.isQueued) { return .resolvingConflicts }
            if run.isQueued { return .queued }
            return running ? .running : .interrupted
        }
        // Stacked on a pull request closed without a merge: back to blocked,
        // its own pull request a draft, until the owner decides.
        if pullRequest?.state == .open, pending?.stack?.drafted == true { return .blocked }
        switch pullRequest?.state {
        case .open: return .openPullRequest
        case .merged: return issue?.isCompleted == true ? .completed : .merged
        default: return issue?.isClosed == true ? .closed : .noPullRequest
        }
    }
}

/// One line of the status report.
struct TaskEntry: Sendable, Equatable {
    let identifier: LinearIssue.Identifier
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
    /// The pull request its own is stacked on, if any.
    var stack: StackBase? = nil
}

/// A section of the status report, as `--status` names it.
enum StatusSection: Hashable, Sendable {
    case awaitingReview
    case drafts
    case task(TaskCategory)
    case done
    case risks
    case stale

    /// Every section, in report order. `awaitingReview` is "Waiting on you":
    /// the pull requests and the proposals waiting in Linear.
    static let all: [StatusSection] =
        [.awaitingReview, .drafts] + TaskCategory.allCases.map(StatusSection.task) + [.done, .risks, .stale]

    var name: String {
        switch self {
        case .awaitingReview: "awaiting-review"
        case .drafts: "drafts"
        case .task(let category): category.name
        case .done: "done"
        case .risks: "risks"
        case .stale: "stale"
        }
    }

    init?(name: String) {
        guard let section = Self.all.first(where: { $0.name == name }) else { return nil }
        self = section
    }
}

/// What `superlinear status` is asked to show, by `--status` and
/// `--workspace`. Nil means everything.
struct StatusFilter: Equatable, Sendable {
    /// The sections to show.
    var sections: Set<StatusSection>? = nil
    /// The workspaces to show, by name.
    var workspaces: [String]? = nil
}

/// What `superlinear status` prints for one workspace, and what
/// `superlinear stats` measures.
struct WorkspaceReport: Sendable {
    let name: String
    var entries: [TaskEntry]
    /// Open pull requests belonging to Linear issues, whether or not the
    /// daemon is tracking the issue. Nil when GitHub or Linear could not be
    /// asked, in which case open pull requests show only among the tasks.
    var reviews: [ReviewEntry]? = nil
    /// The pull requests among `reviews` that wait on the owner, those
    /// holding back the most work first, each stack bottom first. Nil when
    /// not worked out, in which case `reviews` keep their order.
    var waitingOnYou: [WaitingPullRequest]? = nil
    /// The proposals waiting for the owner's answer in Linear.
    var proposalsWaiting: [Proposal] = []
    /// What the daemon did on its own since `since`, oldest first. Nil when
    /// not gathered.
    var done: [String]? = nil
    var since: Date? = nil
    /// What puts the work at risk. Nil when not gathered.
    var risks: [String]? = nil
    /// The entries before `filtered(to:)` left any out, for the notes on
    /// the pull requests listed for review. Nil when none were.
    var unfilteredEntries: [TaskEntry]? = nil
    /// The agents' open and merged pull requests, for `superlinear stats`.
    /// Empty until `measured`.
    var pullRequestStats: [PullRequestStats] = []
    /// Local branches and worktrees no longer needed.
    var stale: [StaleBranch] = []
    /// Branches whose CI the GitHub Actions spending limit stopped, as of
    /// the daemon's last poll.
    var ciStoppedBranches: Set<String> = []
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

            let pending = state.pendingMerges[id]
            let branch = issue?.branchName ?? run?.branchName ?? pending?.branchName ?? ""
            let pullRequest = pullRequests.flatMap { PullRequest.best(for: branch, among: $0) }
            let running = run.map(isRunning) ?? false
            let category = TaskCategory.of(run: run, running: running, issue: issue, pullRequest: pullRequest, pending: pending)

            return TaskEntry(
                identifier: issue?.identifier ?? run?.identifier ?? LinearIssue.Identifier(rawValue: id),
                title: issue?.title ?? "",
                category: category,
                detail: detail(for: category, run: run, issue: issue, pullRequest: pullRequest, pending: pending, runner: runner),
                branch: branch,
                pullRequest: pullRequest,
                stack: run?.stack ?? pending?.stack
            )
        }
        // As of the daemon's last poll, so they need neither Linear nor GitHub.
        let blocked = state.blocked.values.map { waiting in
            TaskEntry(
                identifier: waiting.identifier, title: waiting.title, category: .blocked,
                detail: "blocked by " + waiting.blockers.map(\.rawValue).joined(separator: ", ")
            )
        }
        let needsHuman = state.needsHuman.values.map { waiting in
            TaskEntry(
                identifier: waiting.identifier, title: waiting.title, category: .needsHuman,
                detail: "labeled " + waiting.labels.joined(separator: ", ")
            )
        }
        return (entries + blocked + needsHuman).sorted { a, b in
            a.category == b.category
                ? a.identifier.sortsBefore(b.identifier)
                : a.category < b.category
        }
    }

    private static func detail(
        for category: TaskCategory, run: AgentRun?, issue: LinearIssueStatus?,
        pullRequest: PullRequest?, pending: PendingMerge?, runner: AgentRunner
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
            if run?.usageLimited == true { return "stopped at the Claude usage limit; resumes first when the pause ends" }
            guard let run, run.resumes > 0 else { return nil }
            return "to resume, attempt \(run.resumes + 1)"
        case .blocked:
            // Waiting issues have entries of their own; this one is stacked
            // on a pull request closed without a merge.
            guard let stack = pending?.stack, let pullRequest else { return nil }
            return "blocked by \(stack.identifier): its pull request \(stack.url) was closed without a merge, "
                + "so \(pullRequest.url) is a draft until you decide"
        case .needsHuman:
            return nil
        case .openPullRequest:
            guard let pullRequest else { return nil }
            let stacked = (run?.stack ?? pending?.stack).map { ", stacked on #\($0.number)" } ?? ""
            return (pullRequest.isDraft == true ? "\(pullRequest.url) (draft)" : pullRequest.url) + stacked
        case .merged:
            return [pullRequest?.url, issueState].compactMap { $0 }.joined(separator: ", ")
        case .completed:
            return pullRequest?.url
        case .noPullRequest, .closed:
            return [issueState, pullRequest.map { "\($0.url) (closed)" }].compactMap { $0 }.joined(separator: ", ")
        }
    }

    static let staleHeading = "Stale branches and worktrees"
    static let waitingHeading = "Waiting on you"
    static let doneHeading = "Done autonomously"
    static let risksHeading = "Risks"

    /// The non-draft `reviews` in the order they wait on the owner: as
    /// `waitingOnYou` orders them, then those it leaves out, such as pull
    /// requests an agent is working on, by stack. Each comes with the pull
    /// request it is stacked on and how deep it is in its stack.
    func orderedReviews() -> [(review: ReviewEntry, waiting: WaitingPullRequest?, stackedOn: PullRequest.Number?, level: Int)] {
        let reviews = (reviews ?? []).filter { !$0.pullRequest.isDraft }
        var first: [(ReviewEntry, WaitingPullRequest)] = []
        var placed: Set<PullRequest.Number> = []
        for waiting in waitingOnYou ?? [] {
            for review in reviews where review.pullRequest.number == waiting.pullRequest.number && placed.insert(review.pullRequest.number).inserted {
                first.append((review, waiting))
            }
        }
        // The stacks waitingOnYou lists are in one piece, bottom first.
        let depths = Dictionary(
            Self.byStack(first.map(\.0)).map { ($0.entry.pullRequest.number, $0.level) }, uniquingKeysWith: { a, _ in a })
        return first.map { ($0.0, $0.1, $0.1.stackedOn, depths[$0.0.pullRequest.number] ?? 0) }
            + Self.byStack(reviews.filter { !placed.contains($0.pullRequest.number) }).map { ($0.entry, nil, $0.stackedOn, $0.level) }
    }

    /// The report with only `sections` in it. With neither review section kept, the open pull requests are not listed
    /// for review, so finished tasks with one show among the tasks, as when
    /// the pull requests could not be listed.
    func filtered(to sections: Set<StatusSection>) -> WorkspaceReport {
        var report = self
        report.unfilteredEntries = unfilteredEntries ?? entries
        report.entries = entries.filter { sections.contains(.task($0.category)) }
        let listsReviews = sections.contains(.awaitingReview) || sections.contains(.drafts)
        report.reviews = listsReviews
            ? reviews?.filter { sections.contains($0.pullRequest.isDraft ? .drafts : .awaitingReview) }
            : nil
        if !sections.contains(.awaitingReview) { report.proposalsWaiting = [] }
        if !sections.contains(.done) { report.done = nil }
        if !sections.contains(.risks) { report.risks = nil }
        if !sections.contains(.stale) { report.stale = [] }
        return report
    }

    /// The report as text, one section per category with entries in it.
    func rendered(now: Date = Date()) -> String {
        var lines = [name]
        for warning in warnings {
            lines.append("  warning: \(warning)")
        }
        // Open pull requests are listed for review instead, when they could be.
        let tasks = reviews == nil ? entries : entries.filter { $0.category != .openPullRequest }
        let reviews = reviews ?? []
        if tasks.isEmpty && reviews.isEmpty && proposalsWaiting.isEmpty && stale.isEmpty && warnings.isEmpty
            && done == nil && risks == nil {
            lines.append("  No tasks")
        }
        let width = (tasks.map(\.identifier.rawValue.count) + reviews.map(\.issue.identifier.rawValue.count)).max() ?? 0
        let indent = String(repeating: " ", count: 4 + width + 2)
        // Their pull requests wait on an agent, not on a reviewer.
        var agentAt: [LinearIssue.Identifier: String] = [:]
        let allEntries = unfilteredEntries ?? entries
        for entry in allEntries {
            switch entry.category {
            case .addressingReview: agentAt[entry.identifier] = "agent addressing review"
            case .resolvingConflicts: agentAt[entry.identifier] = "agent resolving conflicts"
            default: break
            }
        }

        // Drafts whose pull request below was closed without a merge.
        var closedBases: [String: StackBase] = [:]
        for entry in allEntries where entry.category == .blocked {
            if let url = entry.pullRequest?.url, let stack = entry.stack { closedBases[url] = stack }
        }
        func describe(
            _ review: ReviewEntry, waiting: WaitingPullRequest?, stackedOn: PullRequest.Number?, level: Int, drafts: Bool
        ) {
            let pullRequest = review.pullRequest
            let nested = String(repeating: "  ", count: level)
            let padded = review.issue.identifier.rawValue.padding(toLength: width, withPad: " ", startingAt: 0)
            lines.append("    \(nested)\(padded)  #\(pullRequest.number) \(pullRequest.title)".trimmingTrailingWhitespace())
            var notes: [String] = []
            if let below = stackedOn { notes.append("stacked on #\(below)") }
            if let closed = closedBases[pullRequest.url] {
                notes.append("stacked on #\(closed.number), closed without a merge: decide what becomes of it")
            }
            if !drafts { notes.append(agentAt[review.issue.identifier] ?? pullRequest.reviewState.rawValue) }
            if pullRequest.mergeable == "CONFLICTING" { notes.append("conflicts with \(pullRequest.baseRefName ?? "base")") }
            notes.append(pullRequest.checkState(stoppedBranches: ciStoppedBranches).rawValue)
            if let blocks = waiting?.blockedIssues.count, blocks > 0 { notes.append("blocks \(blocks) issue\(blocks == 1 ? "" : "s")") }
            lines.append(indent + nested + (notes + [pullRequest.url]).joined(separator: " · "))
        }

        let waiting = orderedReviews()
        if !waiting.isEmpty || !proposalsWaiting.isEmpty {
            lines.append("  \(Self.waitingHeading)")
            for (review, item, stackedOn, level) in waiting {
                describe(review, waiting: item, stackedOn: stackedOn, level: level, drafts: false)
            }
            lines += StatusReview.proposalsWaiting(proposalsWaiting).map { "    " + $0 }
        }
        let drafts = Self.byStack(reviews.filter(\.pullRequest.isDraft))
        if !drafts.isEmpty {
            lines.append("  Draft pull requests")
            for (review, stackedOn, level) in drafts {
                describe(review, waiting: nil, stackedOn: stackedOn, level: level, drafts: true)
            }
        }

        for category in TaskCategory.allCases {
            let section = tasks.filter { $0.category == category }
            guard !section.isEmpty else { continue }
            lines.append("  \(category.heading)")
            for entry in section {
                let padded = entry.identifier.rawValue.padding(toLength: width, withPad: " ", startingAt: 0)
                lines.append("    \(padded)  \(entry.title)".trimmingTrailingWhitespace())
                if let detail = entry.detail, !detail.isEmpty {
                    lines.append(indent + detail)
                }
            }
        }

        if let done {
            let since = since.map { " since \(StatusTime.rendered($0, now: now))" } ?? ""
            lines.append("  \(Self.doneHeading)\(since)")
            lines += done.isEmpty ? ["    Nothing"] : done.map { "    " + $0 }
        }
        if let risks {
            lines.append("  \(Self.risksHeading)")
            lines += risks.isEmpty ? ["    None found"] : risks.map { "    " + $0 }
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

    /// The entries by stack: each pull request after the one it targets, with
    /// that one's number and how deep it is. Pull requests on no listed
    /// branch come in the given order, each followed by its stack.
    static func byStack(_ entries: [ReviewEntry]) -> [(entry: ReviewEntry, stackedOn: PullRequest.Number?, level: Int)] {
        let byHead = Dictionary(entries.map { ($0.pullRequest.headRefName, $0) }, uniquingKeysWith: { a, _ in a })
        func parent(_ entry: ReviewEntry) -> ReviewEntry? {
            entry.pullRequest.baseRefName.flatMap { byHead[$0] }.flatMap { $0.pullRequest.number == entry.pullRequest.number ? nil : $0 }
        }
        var children: [PullRequest.Number: [ReviewEntry]] = [:]
        for entry in entries {
            if let parent = parent(entry) { children[parent.pullRequest.number, default: []].append(entry) }
        }
        var ordered: [(entry: ReviewEntry, stackedOn: PullRequest.Number?, level: Int)] = []
        var placed: Set<PullRequest.Number> = []
        func place(_ entry: ReviewEntry, stackedOn: PullRequest.Number?, level: Int) {
            guard placed.insert(entry.pullRequest.number).inserted else { return }
            ordered.append((entry, stackedOn, level))
            for child in children[entry.pullRequest.number] ?? [] {
                place(child, stackedOn: entry.pullRequest.number, level: level + 1)
            }
        }
        for entry in entries where parent(entry) == nil {
            place(entry, stackedOn: nil, level: 0)
        }
        // Pull requests in a cycle of bases have no bottom; list them alone.
        for entry in entries where !placed.contains(entry.pullRequest.number) {
            place(entry, stackedOn: nil, level: 0)
        }
        return ordered
    }

    /// Gathers the report for one workspace from the state file, Linear and
    /// GitHub. Never throws: what cannot be fetched becomes a warning. What
    /// the tasks took is left for `measured`. `since` is how far back "Done
    /// autonomously" looks.
    static func gather(
        workspace: WorkspaceConfig, state: State, runner: AgentRunner,
        since: TimeInterval, now: Date
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

        let tasks = entries(state: workspaceState, issues: issues, pullRequests: pullRequests, runner: runner)
        let defaultBranch = Git.defaultBranch(in: repoPath)
        var latestRun: WorkflowRun?
        do {
            let runs = try WorkflowRun.list(in: repoPath)
            if let defaultBranch { latestRun = StatusReview.latestRun(runs, on: defaultBranch) }
        } catch {
            warnings.append("Could not list CI runs: \(error)")
        }
        var rateLimit: StatusReview.RateLimit?
        do {
            rateLimit = try StatusReview.decodeRateLimit(try GitHubCLI.run(["api", "rate_limit"], in: repoPath))
        } catch {
            warnings.append("Could not check GitHub's rate limit: \(error)")
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
            waitingOnYou: reviews.map { StatusReview.waitingOnYou($0.map(\.pullRequest), state: workspaceState) },
            proposalsWaiting: workspaceState.proposals.filter(\.isPosted),
            done: StatusReview.done(workspaceState, since: now.addingTimeInterval(-since), now: now),
            since: now.addingTimeInterval(-since),
            risks: StatusReview.risks(
                defaultBranch: defaultBranch, latestRun: latestRun, rateLimit: rateLimit,
                pauses: StatusReview.Pauses(state: state, workspace: workspace.name, now: now), now: now),
            stale: stale,
            ciStoppedBranches: workspaceState.spendingLimit?.branches ?? [],
            warnings: warnings
        )
    }

    /// The report with what its tasks and pull requests took: usage from
    /// the Claude transcripts, CI time from the repository's finished runs,
    /// and each open pull request's size from the local repository.
    /// `superlinear stats` runs this; `status` leaves it out, since it reads
    /// every transcript, lists every CI run and diffs every open branch.
    func measured(repoPath: String, transcripts: Transcripts) -> WorkspaceReport {
        var report = self
        var ciTimes: [String: TimeInterval]?
        if !entries.isEmpty || reviews?.isEmpty == false {
            do {
                let runs = try WorkflowRun.list(in: repoPath)
                // A repository without CI has no CI time, rather than none per task.
                if !runs.isEmpty { ciTimes = WorkflowRun.time(byBranch: runs) }
            } catch {
                report.warnings.append("Could not list CI runs: \(error)")
            }
        }
        for index in report.entries.indices {
            report.entries[index].usage = transcripts.usage(forBranch: entries[index].branch)
            if let ciTimes { report.entries[index].ciTime = ciTimes[entries[index].branch] ?? 0 }
        }

        var stats = PullRequestStats.of(tasks: report.entries, reviews: reviews ?? []) { branch in
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
            report.warnings.append(
                "Local \(base) is ahead of origin/\(base)\(commits), and \(count) open pull request\(count == 1 ? "" : "s") "
                    + "include commits from it, so GitHub shows them larger than they are. Push \(base). "
                    + "The stats measure them from the local fork point.")
        }
        report.pullRequestStats = stats
        return report
    }
}

enum StatusCommand {
    /// A repository whose report hit a GitHub rate limit, to ask GitHub when
    /// it resets; nil when none did.
    static func rateLimitedRepoPath(_ reports: [WorkspaceReport], workspaces: [WorkspaceConfig]) -> String? {
        let workspace = zip(reports, workspaces).first { report, _ in
            report.warnings.contains { $0.localizedCaseInsensitiveContains("rate limit") }
        }?.1
        return workspace.map { NSString(string: $0.repoPath).expandingTildeInPath }
    }

    /// One line for each active pause: of Claude sessions at the usage limit,
    /// and of CI at the GitHub Actions spending limit.
    static func pauseLines(state: State, workspaces: [String], now: Date) -> [String] {
        var lines: [String] = []
        if let pause = state.claudePause, !pause.isOver(now: now) {
            lines.append(pause.rendered(waiting: state.queuedRuns.count, now: now))
        }
        if let line = SpendingLimitStop.rendered(workspaces.compactMap { state.workspaces[$0]?.spendingLimit }, now: now) {
            lines.append(line)
        }
        return lines
    }

    /// Every configured workspace's report, or those `workspaces`, in their
    /// order, gathered at once. With `transcripts`, each is measured too, for
    /// `superlinear stats`. `since` is how far back "Done autonomously" looks.
    /// Warnings about GitHub's rate limit become one header line, rather than
    /// one per GitHub call in every workspace.
    static func reports(
        workspaces: [WorkspaceConfig], state: State, transcripts: Transcripts?, since: TimeInterval
    ) async -> (reports: [WorkspaceReport], header: [String]) {
        let runner = AgentRunner()
        var reports = await withTaskGroup(of: (Int, WorkspaceReport).self) { group in
            for (index, workspace) in workspaces.enumerated() {
                group.addTask {
                    var report = await WorkspaceReport.gather(workspace: workspace, state: state, runner: runner, since: since, now: Date())
                    if let transcripts {
                        let repoPath = NSString(string: workspace.repoPath).expandingTildeInPath
                        report = report.measured(repoPath: repoPath, transcripts: transcripts)
                    }
                    return (index, report)
                }
            }
            var reports: [(Int, WorkspaceReport)] = []
            for await report in group {
                reports.append(report)
            }
            return reports.sorted { $0.0 < $1.0 }.map(\.1)
        }

        var header: [String] = []
        if let repoPath = rateLimitedRepoPath(reports, workspaces: workspaces) {
            for index in reports.indices {
                reports[index].warnings.removeAll { $0.localizedCaseInsensitiveContains("rate limit") }
            }
            let reset = GitHubRateLimit.resetDate(repoPath: repoPath)
            let time = reset.formatted(date: .omitted, time: .shortened)
            header.append("warning: GitHub's rate limit is used up until \(time), so pull requests could not all be listed")
        }
        return (reports, header)
    }

    /// Prints a report for every configured workspace, in config order, or
    /// for those `filter` names, and returns the exit status. `since` is how
    /// far back "Done autonomously" looks; nil for the default.
    static func run(configPath: String?, filter: StatusFilter, since: TimeInterval?) async -> Int32 {
        let config: Config
        do {
            config = try Config.load(from: configPath)
        } catch {
            print("[superlinear] Failed to load config: \(error)")
            return 1
        }
        var workspaces = config.workspaces
        if let names = filter.workspaces {
            let configured = config.workspaces.map(\.name)
            let unknown = names.filter { !configured.contains($0) }
            guard unknown.isEmpty else {
                print("[superlinear] No workspace named \(unknown.joined(separator: ", ")). Workspaces: \(configured.joined(separator: ", "))")
                return 1
            }
            workspaces = config.workspaces.filter { names.contains($0.name) }
        }
        let state = State.loadWithPlanning(from: State.stateFileURL(), planning: PlanningRecord.load())
        var gathered = await reports(workspaces: workspaces, state: state, transcripts: nil, since: since ?? StatusReview.defaultSince)
        if let sections = filter.sections {
            gathered.reports = gathered.reports.map { $0.filtered(to: sections) }
        }
        let names = workspaces.map(\.name)
        let header = gathered.header + pauseLines(state: state, workspaces: names, now: Date())
        let footer = DaemonStatus.read().footer(polls: workspaces.map { ($0.name, state.workspaces[$0.name]?.poll) })
        print((header + gathered.reports.map { $0.rendered() } + [footer]).joined(separator: "\n\n"))
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
