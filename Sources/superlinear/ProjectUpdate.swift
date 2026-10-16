import Foundation

/// An issue in a project, open or recently completed, as project updates and
/// forecasts read it.
struct ProjectIssue: Decodable, Sendable, Equatable {
    var id: LinearIssue.ID
    var identifier: LinearIssue.Identifier
    var title: String
    var branchName: String
    /// 0 for no priority, then 1 (urgent) to 4 (low).
    var priority: Double? = nil
    var sortOrder: Double? = nil
    var startedAt: Date? = nil
    var completedAt: Date? = nil
    var state: State
    var project: Project
    var projectMilestone: Milestone? = nil
    var inverseRelations: LinearIssue.Relations? = nil

    struct State: Decodable, Sendable, Equatable {
        var type: LinearStateType
    }

    struct Project: Decodable, Sendable, Equatable {
        var id: LinearProject.ID
        var name: String
    }

    struct Milestone: Decodable, Sendable, Equatable {
        var id: LinearMilestone.ID
        var name: String
        /// A day, as in 2026-10-25.
        var targetDate: String?
        var sortOrder: Double
    }

    var isOpen: Bool { ![.completed, .canceled].contains(state.type) }

    /// The open issues blocking it.
    var openBlockers: [LinearIssue.ID] {
        (inverseRelations?.nodes ?? [])
            .filter { $0.type == "blocks" && !["completed", "canceled"].contains($0.issue.state.type) }
            .map(\.issue.id)
    }
}

/// What a project update reports for one project.
struct ProjectReport: Sendable, Equatable {
    var projectId: LinearProject.ID
    var projectName: String
    /// Issues completed since the last standup.
    var completed: [LinearIssue.Identifier] = []
    /// Pull requests of the project's issues merged since the last standup.
    var merged: [PullRequest] = []
    /// Decisions entered at this standup on the project's issues.
    var decisions: [StandupDecision] = []
    /// Open issues of the project that need a human.
    var needsHuman: [WaitingIssue] = []
    var milestones: [MilestoneForecast] = []

    /// Whether anything happened since the last standup.
    var hasActivity: Bool { !completed.isEmpty || !merged.isEmpty || !decisions.isEmpty }

    /// The worst health of its milestones, or nil when none has one.
    var health: ProjectHealth? { milestones.compactMap(\.health).max() }
}

/// After each standup, a project update for each project with activity since
/// the last one, and the milestones forecast to be late for the standup's
/// risks.
enum ProjectUpdates {
    static func day(_ date: Date) -> String {
        StandupSession.dayFormatter.string(from: date)
    }

    /// The forecast of each milestone of the projects of `issues`: all of the
    /// workspace's open project issues are scheduled together, as they share
    /// the agents. Milestones by project name, then by sort order.
    static func milestones(
        _ issues: [ProjectIssue], history: ForecastHistory?, agents: Int, now: Date
    ) -> [MilestoneForecast] {
        let open = issues.filter(\.isOpen).sorted(by: workOrder)
        let merges = history.map { history in
            Forecast.schedule(
                open.map {
                    ForecastIssue(
                        id: $0.id, identifier: $0.identifier,
                        blockers: $0.openBlockers, startedAt: $0.state.type == .started ? $0.startedAt : nil)
                },
                history: history, agents: agents, now: now)
        } ?? [:]

        struct Key: Hashable {
            var project: String
            var sortOrder: Double
            var id: LinearMilestone.ID
        }
        var milestones: [Key: (ProjectIssue.Milestone, ProjectIssue.Project)] = [:]
        for issue in issues {
            guard let milestone = issue.projectMilestone else { continue }
            milestones[Key(project: issue.project.name, sortOrder: milestone.sortOrder, id: milestone.id)] =
                (milestone, issue.project)
        }
        let keys = milestones.keys.sorted { a, b in
            a.project != b.project ? a.project < b.project
                : a.sortOrder != b.sortOrder ? a.sortOrder < b.sortOrder : a.id.rawValue < b.id.rawValue
        }
        return keys.map { key in
            let (milestone, project) = milestones[key]!
            let openIssues = open.filter { $0.projectMilestone?.id == milestone.id }
            let forecast = history == nil || openIssues.isEmpty ? nil : openIssues.compactMap { merges[$0.id] }.max()
            let target = milestone.targetDate.flatMap(StandupSession.dayFormatter.date(from:))
            return MilestoneForecast(
                id: milestone.id, name: milestone.name, projectId: project.id, projectName: project.name, targetDate: target,
                openIssues: openIssues.count, forecast: forecast,
                health: Forecast.health(targetDate: target, openIssues: openIssues.count, forecast: forecast, now: now))
        }
    }

    /// Urgent first and no priority last, then by milestone and issue sort order.
    static func workOrder(_ a: ProjectIssue, _ b: ProjectIssue) -> Bool {
        func rank(_ priority: Double?) -> Double {
            guard let priority, priority > 0 else { return .infinity }
            return priority
        }
        let keyA = (rank(a.priority), a.projectMilestone?.sortOrder ?? .infinity, a.sortOrder ?? .infinity)
        let keyB = (rank(b.priority), b.projectMilestone?.sortOrder ?? .infinity, b.sortOrder ?? .infinity)
        return keyA != keyB ? keyA < keyB : a.identifier.sortsBefore(b.identifier)
    }

    /// A report for each project of `issues`, by project name.
    static func reports(
        issues: [ProjectIssue], pullRequests: [PullRequest], decisions: [StandupDecision],
        needsHuman: [LinearIssue.ID: WaitingIssue], milestones: [MilestoneForecast], since: Date
    ) -> [ProjectReport] {
        let byProject = Dictionary(grouping: issues, by: \.project.id)
        return byProject.values.map { issues in
            let project = issues[0].project
            let branches = Set(issues.map(\.branchName))
            let identifiers = Set(issues.map(\.identifier))
            let ids = Set(issues.filter(\.isOpen).map(\.id))
            return ProjectReport(
                projectId: project.id,
                projectName: project.name,
                completed: issues.filter { $0.state.type == .completed && ($0.completedAt ?? .distantPast) >= since }
                    .map(\.identifier).sorted { $0.sortsBefore($1) },
                merged: pullRequests.filter {
                    $0.state == .merged && ($0.mergedAt ?? .distantPast) >= since && branches.contains($0.headRefName ?? "")
                }.sorted { $0.number < $1.number },
                decisions: decisions.filter { identifiers.contains($0.identifier) },
                needsHuman: needsHuman.filter { ids.contains($0.key) }.map(\.value)
                    .sorted { $0.identifier.sortsBefore($1.identifier) },
                milestones: milestones.filter { $0.projectId == project.id }
            )
        }.sorted { $0.projectName < $1.projectName }
    }

    /// The update's text. Every number in it is counted from the state
    /// file, Linear or GitHub, or is a forecast worked out from them.
    static func body(
        _ report: ProjectReport, history: ForecastHistory?, agents: Int, since: Date
    ) -> String {
        func plural(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }
        var lines = [
            "Since \(day(since)): \(plural(report.completed.count, "issue")) completed, "
                + "\(plural(report.merged.count, "pull request")) merged."
        ]
        var details: [String] = []
        if !report.completed.isEmpty { details.append("- Completed: \(StandupView.list(report.completed))") }
        if !report.merged.isEmpty {
            details.append("- Merged: " + report.merged.map { "[#\($0.number)](\($0.url))" }.joined(separator: ", "))
        }
        details += report.decisions.map { "- Decision on \($0.identifier): \($0.text)" }
        if !report.needsHuman.isEmpty {
            details.append("- Needs human: \(StandupView.list(report.needsHuman.map(\.identifier)))")
        }
        if !details.isEmpty { lines += [""] + details }

        if !report.milestones.isEmpty {
            lines += ["", "Milestones:"]
            lines += report.milestones.map { "- " + describe($0) }
        }
        lines.append("")
        if let history {
            lines.append(
                "Forecast from the last \(plural(history.count, "completed issue")): median agent time "
                    + "\(StatusSummary.duration(history.agentTime)), median start to merge "
                    + "\(StatusSummary.duration(history.startToMerge)), at most \(plural(agents, "agent")) at once.")
        } else {
            lines.append("No forecast: no completed issue has both an agent time and a start-to-merge time yet.")
        }
        return lines.joined(separator: "\n")
    }

    static func describe(_ milestone: MilestoneForecast) -> String {
        guard milestone.openIssues > 0 else { return "\(milestone.name): no open issues" }
        var parts = ["\(milestone.name): \(milestone.openIssues) open"]
        if let forecast = milestone.forecast { parts.append("forecast \(day(forecast))") }
        parts.append(milestone.targetDate.map { "target \(day($0))" } ?? "no target date")
        if let health = milestone.health { parts.append(health.rendered) }
        return parts.joined(separator: ", ")
    }

    /// The standup's risk lines for milestones at risk or off track.
    static func risks(_ milestones: [MilestoneForecast]) -> [String] {
        milestones.compactMap { milestone in
            let name = "Milestone \(milestone.projectName) › \(milestone.name)"
            let target = milestone.targetDate.map(day) ?? ""
            switch milestone.health {
            case .offTrack?:
                return "\(name): target \(target) passed with \(milestone.openIssues) open issue\(milestone.openIssues == 1 ? "" : "s")"
            case .atRisk?:
                return "\(name): forecast \(milestone.forecast.map(day) ?? ""), after its target \(target)"
            default:
                return nil
            }
        }
    }

    /// A proposal draft for each project with activity since `since`.
    static func drafts(
        _ reports: [ProjectReport], history: ForecastHistory?, agents: Int, since: Date, now: Date
    ) -> [ProposalDraft] {
        reports.filter(\.hasActivity).map { report in
            ProposalDraft(
                payload: .postProjectUpdate(
                    body: body(report, history: history, agents: agents, since: since), health: report.health),
                target: .project(report.projectId, name: report.projectName),
                reason: "Activity in \(report.projectName) since the standup of \(day(since))",
                source: ProposalSource(kind: .standup, value: day(now))
            )
        }
    }

    /// The samples the forecast learns from: the issues the daemon processed
    /// that are completed in Linear and whose pull request merged, with the
    /// time their agents were active.
    static func samples(
        issues: [LinearIssueStatus], pullRequests: [PullRequest], agentTime: (String) -> TimeInterval?
    ) -> [CompletedIssueSample] {
        issues.filter(\.isCompleted).compactMap { issue in
            guard let pullRequest = PullRequest.best(for: issue.branchName, among: pullRequests),
                  pullRequest.state == .merged, let mergedAt = pullRequest.mergedAt
            else { return nil }
            let startToMerge = issue.startedAt.map { mergedAt.timeIntervalSince($0) }.flatMap { $0 > 0 ? $0 : nil }
            return CompletedIssueSample(
                identifier: issue.identifier, mergedAt: mergedAt,
                agentTime: agentTime(issue.branchName), startToMerge: startToMerge)
        }
    }
}

/// What a standup gathers for milestone forecasts and project updates.
struct ProjectForecast: Sendable {
    var history: ForecastHistory?
    /// The repository's pull requests, with their merge times.
    var pullRequests: [PullRequest] = []
    var agents: Int
    /// The projects' open issues, and those completed since the last standup.
    var issues: [ProjectIssue] = []
    var milestones: [MilestoneForecast] = []
    /// Problems that left the forecast incomplete.
    var warnings: [String] = []
    /// Fetches the projects' issues again, as the standup may have completed some.
    var refetch: @Sendable () async throws -> [ProjectIssue]

    /// Gathers the forecast of one workspace's milestones. Never throws: what
    /// cannot be fetched becomes a warning.
    static func gather(
        _ workspace: WorkspaceConfig, state: WorkspaceState, agents: Int, since: Date, now: Date = Date()
    ) async -> ProjectForecast {
        let client = LinearClient(apiKey: workspace.apiKey)
        let refetch: @Sendable () async throws -> [ProjectIssue] = {
            try await client.fetchProjectIssues(completedSince: since, teamIds: workspace.teamIds)
        }
        var forecast = ProjectForecast(agents: agents, refetch: refetch)
        let repoPath = NSString(string: workspace.repoPath).expandingTildeInPath
        do {
            forecast.pullRequests = try await PullRequestChecker().allPullRequests(repoPath: repoPath)
        } catch {
            forecast.warnings.append("Could not list pull requests for the forecast: \(error)")
        }
        if !state.processedIssueIds.isEmpty && !forecast.pullRequests.isEmpty {
            do {
                let processed = try await client.fetchIssues(ids: state.processedIssueIds.sorted())
                let transcripts = Transcripts()
                let samples = ProjectUpdates.samples(issues: processed, pullRequests: forecast.pullRequests) {
                    transcripts.usage(forBranch: $0)?.activeTime
                }
                forecast.history = ForecastHistory.of(samples)
            } catch {
                forecast.warnings.append("Could not fetch completed issues from Linear for the forecast: \(error)")
            }
        }
        do {
            forecast.issues = try await refetch()
            forecast.milestones = ProjectUpdates.milestones(
                forecast.issues, history: forecast.history, agents: agents, now: now)
        } catch {
            forecast.warnings.append("Could not fetch project issues from Linear: \(error)")
        }
        return forecast
    }

    /// The proposals made, and what became of them, a line each.
    struct Made: Sendable {
        var proposals: [Proposal] = []
        var summary: [String] = []
    }

    /// Proposes an update for each project with activity since `since`, and
    /// applies those whose kind is `auto` at once. `existing` are the
    /// workspace's proposals so far.
    func proposeUpdates(
        engine: ProposalEngine, existing: [Proposal], decisions: [StandupDecision],
        needsHuman: [LinearIssue.ID: WaitingIssue], since: Date, now: Date = Date()
    ) async -> Made {
        var made = Made()
        var issues = issues
        do {
            issues = try await refetch()
        } catch {
            made.summary.append("Could not fetch project issues again, so project updates use those from before: \(error)")
        }
        let milestones = ProjectUpdates.milestones(issues, history: history, agents: agents, now: now)
        let reports = ProjectUpdates.reports(
            issues: issues, pullRequests: pullRequests, decisions: decisions, needsHuman: needsHuman,
            milestones: milestones, since: since)
        let drafts = ProjectUpdates.drafts(reports, history: history, agents: agents, since: since, now: now)
        for draft in drafts {
            let name = draft.target.name ?? draft.target.rawID
            let screening: ProposalEngine.Screening
            do {
                screening = try await engine.screen(draft, existing: existing + made.proposals, now: now)
            } catch {
                made.summary.append("Could not propose an update for \(name): \(error)")
                continue
            }
            switch screening {
            case .skip(let reason):
                made.summary.append("No update for \(name): \(reason)")
            case .store(let proposal, let applyNow):
                guard applyNow else {
                    made.proposals.append(proposal)
                    made.summary.append("Proposed an update for \(name), for the next standup")
                    continue
                }
                let result = await engine.apply(proposal, now: now)
                made.proposals.append(result)
                made.summary.append(result.status == .applied
                    ? "Posted an update for \(name)"
                    : "Could not post an update for \(name), so it waits for the next standup: "
                        + (result.lastError ?? result.reviewNote ?? result.rejectionReason ?? "unknown"))
            }
        }
        return made
    }
}
