import Foundation

/// A proposal waiting for the owner in Linear, as the roadmap sees it.
struct RoadmapProposal: Codable, Sendable, Equatable {
    var kind: ProposalKind
    var reason: String
    var form: ProposalPost.Form
    /// The issue created for it, or the issue its comment is on.
    var issue: LinearIssue.Identifier?
    var url: String?
}

/// An open pull request of one of the workspace's issues.
struct RoadmapPullRequest: Codable, Sendable, Equatable {
    var number: PullRequest.Number
    var title: String
    var url: String
    var issues: [LinearIssue.Identifier]
    var isDraft: Bool
    /// As `ReviewablePullRequest.ReviewState` and `CheckState` say them.
    var review: String
    var ci: String
    /// Whether it waits on the owner, as "Waiting on you" in `status` says.
    var waitingOnYou: Bool
}

/// One workspace's part of what a roadmap session is given: the same reads
/// `superlinear status` and the planning job make.
struct RoadmapWorkspace: Codable, Sendable, Equatable {
    var name: String
    var defaultBranch: String?
    var head: GitCommit.SHA?
    /// The worktree with the default branch checked out, or the repository.
    var worktreePath: String
    var teams: [PlanningTeam]
    /// The open issues of the watched teams.
    var issues: [PlanningIssue]
    /// The proposals waiting for the owner in Linear.
    var proposals: [RoadmapProposal]
    var pullRequests: [RoadmapPullRequest]
    /// Issues waiting for their blockers, as of the daemon's last poll.
    var blocked: [WaitingIssue]
    var humanLabels: [String]
    /// The default branch's recent commits, newest first.
    var recentMerges: [PlanningCommit]
    var warnings: [String] = []

    var teamKeys: [String] { Array(Set(teams.map { $0.key.rawValue.uppercased() } + issues.map { $0.teamKey.rawValue.uppercased() })).sorted() }

    /// Why the owner acts on `issue`, by the rules the data settles: a human
    /// label, Triage, a proposal waiting for an answer, a pull request
    /// waiting for review.
    func ownerReasons(for issue: PlanningIssue) -> [OwnerReason] {
        var reasons: [OwnerReason] = []
        let human = Set(humanLabels.map { $0.lowercased() })
        let labels = issue.labels.map(\.rawValue).filter { human.contains($0.lowercased()) }
        if !labels.isEmpty {
            reasons.append(OwnerReason(kind: .humanLabel, text: "labeled \(labels.joined(separator: ", ")): do it yourself", url: issue.url))
        }
        let proposals = proposals.filter { $0.issue == issue.identifier }
        if let proposed = proposals.first(where: { $0.form != .comment }) {
            let place = proposed.form == .triageIssue ? "Triage" : "Backlog"
            reasons.append(
                OwnerReason(kind: .triage, text: "accept or reject the proposed issue in \(place)", url: proposed.url ?? issue.url))
        } else if issue.stateType == .triage {
            reasons.append(OwnerReason(kind: .triage, text: "triage it", url: issue.url))
        }
        for proposal in proposals where proposal.form == .comment {
            reasons.append(
                OwnerReason(
                    kind: .proposal, text: "answer the proposal to \(proposal.kind.rawValue): \(proposal.reason)",
                    url: proposal.url ?? issue.url))
        }
        for pullRequest in pullRequests where pullRequest.waitingOnYou && pullRequest.issues.contains(issue.identifier) {
            let verb = pullRequest.review == ReviewablePullRequest.ReviewState.approved.rawValue ? "merge" : "review"
            reasons.append(
                OwnerReason(kind: .review, text: "\(verb) #\(pullRequest.number) (\(pullRequest.review), \(pullRequest.ci))", url: pullRequest.url))
        }
        return reasons
    }
}

/// Everything a roadmap session is given, kept beside it so its output can
/// be checked against it.
struct RoadmapContext: Codable, Sendable, Equatable {
    var builtAt: Date
    var workspaces: [RoadmapWorkspace]
    var references: [CrossReference]
    var warnings: [String] = []

    init(builtAt: Date, workspaces: [RoadmapWorkspace], warnings: [String] = []) {
        self.builtAt = builtAt
        self.workspaces = workspaces
        self.references = CrossReference.find(in: workspaces)
        self.warnings = warnings + workspaces.flatMap { workspace in workspace.warnings.map { "\(workspace.name): \($0)" } }
    }
}

/// Gathers the context of a roadmap from Linear, GitHub, git and the state file.
enum RoadmapGatherer {
    /// How far back the recent merges go.
    static let mergeLookback: TimeInterval = 7 * 24 * 60 * 60
    /// At most this many recent merges per workspace.
    static let mergeLimit = 30

    static func gather(workspaces: [WorkspaceConfig], state: State, now: Date) async -> RoadmapContext {
        let gathered = await withTaskGroup(of: (Int, RoadmapWorkspace).self) { group in
            for (index, workspace) in workspaces.enumerated() {
                group.addTask {
                    (index, await gather(workspace, state: state.workspaces[workspace.name] ?? WorkspaceState(), now: now))
                }
            }
            var all: [(Int, RoadmapWorkspace)] = []
            for await item in group { all.append(item) }
            return all.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return RoadmapContext(builtAt: now, workspaces: gathered)
    }

    /// One workspace's part. Never throws: what cannot be read becomes a warning.
    static func gather(_ workspace: WorkspaceConfig, state: WorkspaceState, now: Date) async -> RoadmapWorkspace {
        let repoPath = NSString(string: workspace.repoPath).expandingTildeInPath
        var warnings: [String] = []
        let linear = LinearClient(apiKey: workspace.apiKey)
        var issues: [PlanningIssue] = []
        var teams: [PlanningTeam] = []
        do {
            issues = try await linear.planningIssues(teamIds: workspace.watchedTeams)
            teams = try await linear.planningTeams(ids: workspace.watchedTeams)
        } catch {
            warnings.append("Could not read the open issues from Linear: \(error)")
        }

        let branch = PlanningGit.defaultBranch(repoPath: repoPath)
        var head: GitCommit.SHA?
        var merges: [PlanningCommit] = []
        var worktree = repoPath
        if let branch {
            worktree = PlanningGit.worktree(of: branch, repoPath: repoPath) ?? repoPath
            if Git.run(["fetch", "--quiet", "origin", branch], in: repoPath) == nil {
                warnings.append("Could not fetch \(branch); its commits are those known locally")
            }
            let ref = PlanningGit.ref(of: branch, repoPath: repoPath)
            head = Git.run(["rev-parse", "--verify", "--quiet", ref], in: repoPath).map { GitCommit.SHA(rawValue: $0) }
            merges = Array(
                PlanningGit.commits(repoPath: repoPath, since: nil, through: ref, notBefore: now.addingTimeInterval(-mergeLookback))
                    .prefix(mergeLimit))
        } else {
            warnings.append(PlanningError.noDefaultBranch(repoPath).description)
        }

        let open = Set(issues.map(\.identifier))
        var pullRequests: [RoadmapPullRequest] = []
        do {
            let listed = try ReviewablePullRequest.listOpen(in: repoPath)
            let waiting = Set(StatusReview.waitingOnYou(listed, state: state).map(\.pullRequest.number))
            let stopped = state.spendingLimit?.branches ?? []
            pullRequests = listed.compactMap { pullRequest in
                let named = pullRequest.issueIdentifiers.filter(open.contains)
                guard !named.isEmpty else { return nil }
                return RoadmapPullRequest(
                    number: pullRequest.number, title: pullRequest.title, url: pullRequest.url, issues: named,
                    isDraft: pullRequest.isDraft, review: pullRequest.reviewState.rawValue,
                    ci: pullRequest.checkState(stoppedBranches: stopped).rawValue, waitingOnYou: waiting.contains(pullRequest.number))
            }
        } catch {
            warnings.append("Could not list the open pull requests: \(error)")
        }

        let proposals: [RoadmapProposal] = state.proposals.filter(\.isPosted).compactMap { proposal in
            guard let post = proposal.post else { return nil }
            return RoadmapProposal(
                kind: proposal.kind, reason: proposal.reason, form: post.form,
                issue: post.issueIdentifier.map { LinearIssue.Identifier(rawValue: $0) }, url: post.url)
        }

        return RoadmapWorkspace(
            name: workspace.name, defaultBranch: branch, head: head, worktreePath: worktree, teams: teams, issues: issues,
            proposals: proposals, pullRequests: pullRequests,
            blocked: state.blocked.values.sorted { $0.identifier.sortsBefore($1.identifier) },
            humanLabels: workspace.humanLabels, recentMerges: merges, warnings: warnings)
    }
}

/// What a roadmap session is told.
enum RoadmapPrompt {
    /// The prompt that starts the session, which writes its roadmap to
    /// `outputPath`. `commands` holds, by workspace name, the script that
    /// runs each of `git`, `gh` and `linctl` for that workspace.
    static func render(_ context: RoadmapContext, outputPath: String, commands: [String: [String: String]]) -> String {
        var lines: [String] = [
            """
            You are superlinear's roadmap session for the Linear workspaces \
            \(context.workspaces.map { "\"\($0.name)\"" }.joined(separator: ", ")). You run headless: do not ask \
            questions. The owner wants to know the order of the open work across all of them, who does each step \
            (an agent superlinear starts, or the owner), and what the owner must do now so that agents are not \
            waiting.

            Each workspace's repository is open to you at the path below, with its default branch checked out. \
            Read the code with Read, Grep and Glob. Each workspace has its own `git`, `gh` and `linctl` commands, \
            given below, which run in its repository and read its Linear with its key. Run them as you need: \
            `git log`, `git show` and `git diff`; `gh pr view` and `gh pr list`; `linctl issue get <identifier>`, \
            `linctl issue list` and `linctl issue search <words>`, each with the workspace's command in place of \
            `git`, `gh` or `linctl`. Do not run other commands, and do not change Linear, the repositories or \
            anything else.

            Your only output is a JSON file, written with the Write tool to:

                \(outputPath)

            It holds one object:

                {
                  "steps": [
                    {"work": "TEM-50 (tests do not compile on main)", "issues": ["TEM-50"], "who": ["agent"], "why": "…"},
                    {"work": "Release workflows 4.2.0", "issues": [], "who": ["you"], "why": "…"},
                    {"work": "TLS-5 (…), then release tools 5.x", "issues": ["TLS-5"], "who": ["agent", "you"], "why": "…"}
                  ],
                  "actions": [{"text": "Release workflows 4.2.0", "step": 2, "issues": []}],
                  "triage": [{"text": "TEM-31 and TEM-33 are the same work", "issues": ["TEM-31", "TEM-33"]}]
                }

            Rules:

            1. Steps are in the order the work should be done; earlier steps unblock later ones. Put every open \
            issue listed below in exactly one step; issues that belong together may share a step. A step may also \
            be an action outside Linear that the issues name: a release, a tag, a key, a purchase, an account.
            2. `work` says what the step is, naming each issue by its identifier followed by a short title in \
            parentheses. `issues` lists its issues' identifiers. `who` lists who does it, in order, each `agent` \
            or `you`; `["agent", "you"]` reads "agent, then you". `why` says in one sentence why it is in its place.
            3. Who is `you` when an issue is marked below as needing the owner (a human label, Triage, a proposal \
            waiting for an answer, a pull request waiting for review), or when the step is an action outside \
            Linear. Otherwise it is `agent`.
            4. `actions` are what the owner must do now so that agents are not waiting, most urgent first, each \
            with the number of the step it unblocks, counting from 1.
            5. `triage` notes duplicates, issues that belong together, and issues that should be split or closed.
            6. "Waits across workspaces" below lists issues whose description names an issue of another workspace. \
            Linear cannot relate them; treat each as a dependency: the named issue goes first.
            """,
        ]
        let index = RoadmapIssueIndex(context)
        let shared = index.shared
        if !shared.isEmpty {
            lines.append(
                """
                7. More than one workspace has issues with these identifiers: \(shared.sorted().joined(separator: ", ")). \
                Name each of those issues with its workspace, as `\(index.all.first { shared.contains($0.identifier.rawValue.uppercased()) }.map { "\($0.workspace):\($0.identifier)" } ?? "")`, \
                in `issues` and in the text.
                """)
        }

        if !context.references.isEmpty {
            lines.append("\n## Waits across workspaces\n")
            for reference in context.references { lines.append("- " + reference.rendered(step: nil)) }
        }

        for workspace in context.workspaces {
            lines.append("\n# Workspace \"\(workspace.name)\"\n")
            var facts = ["Repository: \(workspace.worktreePath)"]
            if let branch = workspace.defaultBranch {
                facts.append("Default branch: \(branch)" + (workspace.head.map { " at \($0.short)" } ?? ""))
            }
            for (tool, command) in (commands[workspace.name] ?? [:]).sorted(by: { $0.key < $1.key }) {
                facts.append("`\(tool)`: `\(command)`")
            }
            facts.append("Teams: " + workspace.teams.map { "\($0.key) (\($0.name))" }.joined(separator: ", "))
            facts.append("Human labels: " + workspace.humanLabels.joined(separator: ", "))
            lines.append(facts.map { "- \($0)" }.joined(separator: "\n"))
            for warning in workspace.warnings { lines.append("- Warning: \(warning)") }

            lines.append("\n## Recent commits on \(workspace.defaultBranch ?? "the default branch")\n")
            if workspace.recentMerges.isEmpty { lines.append("None in the last \(Int(RoadmapGatherer.mergeLookback / 86400)) days.") }
            for commit in workspace.recentMerges {
                lines.append("- \(commit.sha.short) \(commit.subject) (\(ISO8601DateFormatter().string(from: commit.date)))")
            }

            lines.append("\n## Open pull requests\n")
            if workspace.pullRequests.isEmpty { lines.append("None.") }
            for pullRequest in workspace.pullRequests {
                var line = "- #\(pullRequest.number) \(pullRequest.title) — issues \(pullRequest.issues.map(\.rawValue).joined(separator: ", "))"
                line += " — \(pullRequest.isDraft ? "draft, " : "")\(pullRequest.review), \(pullRequest.ci)"
                if pullRequest.waitingOnYou { line += " — waits on the owner" }
                lines.append(line)
            }

            lines.append("\n## Proposals waiting for the owner\n")
            if workspace.proposals.isEmpty { lines.append("None.") }
            for proposal in workspace.proposals {
                let place = proposal.form == .comment ? "a comment on" : "the proposed issue"
                lines.append("- \(proposal.kind.rawValue), \(place) \(proposal.issue?.rawValue ?? "an issue"): \(proposal.reason)")
            }

            if !workspace.blocked.isEmpty {
                lines.append("\n## Blocked, as of the daemon's last poll\n")
                for waiting in workspace.blocked {
                    lines.append("- \(waiting.identifier) blocked by \(waiting.blockers.map(\.rawValue).joined(separator: ", "))")
                }
            }

            lines.append("\n## Open issues\n")
            if workspace.issues.isEmpty { lines.append("None.") }
            for issue in workspace.issues.sorted(by: { $0.identifier.sortsBefore($1.identifier) }) {
                let identifier = shared.contains(issue.identifier.rawValue.uppercased()) ? "\(workspace.name):\(issue.identifier)" : issue.identifier.rawValue
                lines.append("### \(identifier): \(issue.title)\n")
                var facts = ["State: \(issue.stateName) (\(issue.stateType.rawValue))"]
                if let priority = issue.priority, priority.rawValue > 0 { facts.append("Priority: \(Int(priority.rawValue))") }
                if let project = issue.projectName { facts.append("Project: \(project)") }
                if let milestone = issue.milestone { facts.append("Milestone: \(milestone)") }
                if !issue.labels.isEmpty { facts.append("Labels: \(issue.labels.map(\.rawValue).joined(separator: ", "))") }
                if !issue.relations.isEmpty { facts.append("Relations: \(issue.relations.map(\.rendered).joined(separator: ", "))") }
                lines.append(facts.joined(separator: " · "))
                let owner = workspace.ownerReasons(for: issue)
                if !owner.isEmpty { lines.append("Needs the owner: " + owner.map(\.text).joined(separator: "; ")) }
                lines.append("")
                lines.append(issue.description.isEmpty ? "(No description.)" : issue.description)
                lines.append("")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The prompt that resumes an interrupted session.
    static func resume(outputPath: String) -> String {
        """
        You were interrupted. Carry on where you left off, and write the roadmap file to \(outputPath) as \
        your instructions say.
        """
    }
}
