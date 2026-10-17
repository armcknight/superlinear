import Foundation

/// An open issue as the planning job sees it.
struct PlanningIssue: Codable, Sendable, Equatable {
    var id: LinearIssue.ID
    var identifier: LinearIssue.Identifier
    var title: String
    var description: String
    /// The name the team gives the state, as "In Review"; teams name their
    /// own, so only `stateType` is one of a known set.
    var stateName: String
    var stateType: LinearStateType
    var priority: LinearIssue.Priority?
    var teamId: LinearTeam.ID
    var teamKey: LinearTeam.Key
    var projectId: LinearProject.ID?
    var projectName: LinearProject.Name?
    var milestone: LinearMilestone.Name?
    var labels: [LinearLabel.Name]
    var relations: [PlanningRelation]
    var updatedAt: Date

    var createdBySuperlinear: Bool { labels.contains { $0.rawValue.caseInsensitiveCompare(ProposalEngine.label) == .orderedSame } }
    var handsOff: Bool { labels.contains { $0.rawValue.caseInsensitiveCompare(ProposalEngine.handsOffLabel) == .orderedSame } }

    /// The text an edit replaces: the whole description of an issue
    /// superlinear created, otherwise its managed block.
    var editableText: String {
        createdBySuperlinear ? description : ManagedBlock.contents(of: description) ?? ""
    }
}

/// A relation between an open issue and another.
struct PlanningRelation: Codable, Sendable, Equatable {
    var type: LinearRelationType
    var identifier: LinearIssue.Identifier
    var direction: Direction

    /// Which end of the relation the issue is.
    enum Direction: String, Codable, Sendable {
        /// The issue is the relation's subject: the one that blocks, or is
        /// the duplicate.
        case outgoing
        /// The issue is the relation's object: the one blocked, or duplicated.
        case incoming
    }

    var rendered: String {
        switch (type, direction) {
        case (.blocks, .outgoing): "blocks \(identifier)"
        case (.blocks, .incoming): "blocked by \(identifier)"
        case (.duplicate, .outgoing): "duplicate of \(identifier)"
        case (.duplicate, .incoming): "duplicated by \(identifier)"
        default: "\(type.rawValue) to \(identifier)"
        }
    }
}

struct PlanningProject: Codable, Sendable, Equatable {
    var id: LinearProject.ID
    var name: LinearProject.Name
    var content: String
    var updatedAt: Date
    var milestones: [Milestone]

    struct Milestone: Codable, Sendable, Equatable {
        var name: LinearMilestone.Name
    }
}

struct PlanningTeam: Codable, Sendable, Equatable {
    var id: LinearTeam.ID
    var key: LinearTeam.Key
    var name: String
}

struct PlanningSpec: Codable, Sendable, Equatable {
    var id: LinearDocument.ID
    var url: String
    var content: String
    var updatedAt: Date
}

/// A pull request merged into the default branch.
struct PlanningPullRequest: Codable, Sendable, Equatable {
    var number: PullRequest.Number
    var title: String
    var url: String
    var headRefName: String
}

/// A commit on the default branch.
struct PlanningCommit: Codable, Sendable, Equatable {
    var sha: GitCommit.SHA
    var author: String
    var date: Date
    var subject: String
    var body: String
    var pullRequest: PlanningPullRequest?
    /// The Linear issues it names, in its message or its pull request.
    var issues: [LinearIssue.Identifier] = []
}

/// Everything the planning job's session is given, kept beside the run so
/// that its output can be checked against it, also after a restart.
struct PlanningContext: Codable, Sendable, Equatable {
    var workspace: String
    /// Why the job runs, as `PlanningTrigger` describes it.
    var trigger: String
    var defaultBranch: String
    var worktreePath: String
    /// The default branch's head on the remote, or locally when there is none.
    var head: GitCommit.SHA
    /// The head the last job looked at, when there was one.
    var since: GitCommit.SHA?
    /// The default branch's commits after `since`, newest first.
    var commits: [PlanningCommit]
    /// The issues completed since the last job ended, which are no longer
    /// among `issues`.
    var completedIssues: [LinearIssue.Identifier]
    var issues: [PlanningIssue]
    var projects: [PlanningProject]
    var teams: [PlanningTeam]
    var spec: PlanningSpec?
    /// Problems gathering it that did not stop the job.
    var warnings: [String] = []

    func issue(_ identifier: String?) -> PlanningIssue? {
        guard let identifier = identifier?.trimmingCharacters(in: .whitespaces).uppercased(), !identifier.isEmpty
        else { return nil }
        return issues.first { $0.identifier.rawValue.uppercased() == identifier }
    }

    /// The range of commits it covers, as `abc1234..def5678`, or the head alone.
    var range: String {
        guard let oldest = commits.last else { return head.short }
        return "\((since ?? oldest.sha).short)..\(head.short)"
    }
}

/// The reads in Linear that the planning job needs. `LinearClient` does them
/// for real; tests stand in for it.
protocol PlanningReading: Sendable {
    /// Open issues in the teams, or in every team when `teamIds` is empty.
    func planningIssues(teamIds: [LinearTeam.ID]) async throws -> [PlanningIssue]
    func planningProjects(ids: [LinearProject.ID]) async throws -> [PlanningProject]
    /// The teams with these IDs, or every team when `ids` is empty.
    func planningTeams(ids: [LinearTeam.ID]) async throws -> [PlanningTeam]
    /// The issues in the teams, or in every team when `teamIds` is empty,
    /// completed after `after`, oldest first.
    func completedIssues(teamIds: [LinearTeam.ID], after: Date) async throws -> [LinearIssue.Identifier]
    func spec(of target: ProposalTarget) async throws -> SpecText
}

enum PlanningError: Error, CustomStringConvertible {
    case noDefaultBranch(String)
    case noWorktree(branch: String, repoPath: String)
    case noHead(String)
    case noOutput(String)

    var description: String {
        switch self {
        case .noDefaultBranch(let repoPath): "Could not find the default branch of \(repoPath)"
        case .noWorktree(let branch, let repoPath): "No worktree of \(repoPath) has \(branch) checked out"
        case .noHead(let ref): "Could not read the head of \(ref)"
        case .noOutput(let path): "The session wrote no proposals file at \(path)"
        }
    }
}

/// The git reads the planning job makes in the repository.
enum PlanningGit {
    /// The branch `origin/HEAD` points at, or else `main` or `master`,
    /// whichever exists.
    static func defaultBranch(repoPath: String) -> String? {
        Git.defaultBranch(in: repoPath)
            ?? ["main", "master"].first { Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\($0)"], in: repoPath) != nil }
    }

    /// The path of the worktree that has `branch` checked out.
    static func worktree(of branch: String, repoPath: String) -> String? {
        guard let list = Git.run(["worktree", "list", "--porcelain"], in: repoPath) else { return nil }
        var path: String?
        for line in list.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
            } else if line == "branch refs/heads/\(branch)" {
                return path
            }
        }
        return nil
    }

    /// The remote's ref for `branch` when there is one, else the local branch.
    static func ref(of branch: String, repoPath: String) -> String {
        let remote = "refs/remotes/origin/\(branch)"
        return Git.run(["rev-parse", "--verify", "--quiet", remote], in: repoPath) != nil ? remote : "refs/heads/\(branch)"
    }

    /// The head of `branch` on the remote, asked with `git ls-remote` so that
    /// a poll fetches nothing, or, when the remote cannot be asked, the head
    /// of `ref(of:)`. Nil when neither is known.
    static func head(of branch: String, repoPath: String) -> GitCommit.SHA? {
        if let answer = Git.run(["ls-remote", "--heads", "origin", "refs/heads/\(branch)"], in: repoPath),
           let sha = answer.split(whereSeparator: { $0 == "\t" || $0 == "\n" }).first, sha.count == 40 {
            return GitCommit.SHA(rawValue: String(sha))
        }
        return Git.run(["rev-parse", "--verify", "--quiet", ref(of: branch, repoPath: repoPath)], in: repoPath)
            .map { GitCommit.SHA(rawValue: $0) }
    }

    /// Moves the worktree's branch up to `ref` when it is clean and behind it,
    /// so the session reads the code as merged. Returns why it did not, if it
    /// had to and could not.
    static func fastForward(worktree: String, to ref: String) -> String? {
        guard let head = Git.run(["rev-parse", "HEAD"], in: worktree),
              let target = Git.run(["rev-parse", ref], in: worktree), head != target
        else { return nil }
        guard Git.run(["status", "--porcelain"], in: worktree) == "" else {
            return "\(worktree) has uncommitted changes, so it was left at \(head.prefix(7)) rather than \(target.prefix(7))"
        }
        guard Git.run(["merge", "--ff-only", "--quiet", ref], in: worktree) != nil else {
            return "\(worktree) could not be fast-forwarded to \(target.prefix(7)), so it was left at \(head.prefix(7))"
        }
        return nil
    }

    /// At most this many commits are given to a job.
    static let commitLimit = 100

    /// The first-parent commits of `ref` after `since`, newest first, or,
    /// with no `since` or one git no longer has, those since `notBefore`.
    static func commits(repoPath: String, since: GitCommit.SHA?, through ref: String, notBefore: Date) -> [PlanningCommit] {
        var arguments = ["log", "--first-parent", "-n", "\(commitLimit)", "--format=%H%x1f%an%x1f%aI%x1f%s%x1f%b%x1e"]
        if let since, Git.run(["cat-file", "-e", "\(since)^{commit}"], in: repoPath) != nil {
            arguments.append("\(since)..\(ref)")
        } else {
            arguments += ["--since=\(ISO8601DateFormatter().string(from: notBefore))", ref]
        }
        guard let output = Git.run(arguments, in: repoPath) else { return [] }
        let formatter = ISO8601DateFormatter()
        return output.split(separator: "\u{1e}").compactMap { record in
            let fields = record.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\u{1f}")
            guard fields.count == 5, let date = formatter.date(from: fields[2]) else { return nil }
            return PlanningCommit(
                sha: GitCommit.SHA(rawValue: fields[0]), author: fields[1], date: date, subject: fields[3],
                body: fields[4].trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// The identifiers of issues in teams with `keys` that `texts` name, as
    /// `SPL-11` or a branch's `spl-11`, in the order first named.
    static func identifiers(in texts: [String], keys: Set<LinearTeam.Key>) -> [LinearIssue.Identifier] {
        let keys = Set(keys.map { $0.rawValue.uppercased() })
        let pattern = /(?i)\b([a-z][a-z0-9]*)-([0-9]+)\b/
        var found: [LinearIssue.Identifier] = []
        for text in texts {
            for match in text.matches(of: pattern) {
                let key = match.output.1.uppercased()
                guard keys.contains(key) else { continue }
                let identifier = LinearIssue.Identifier(rawValue: "\(key)-\(match.output.2)")
                if !found.contains(identifier) { found.append(identifier) }
            }
        }
        return found
    }
}

/// A merged pull request as `gh pr list --json` reports it.
struct MergedPullRequest: Decodable, Sendable, Equatable {
    var number: PullRequest.Number
    var title: String
    var url: String
    var headRefName: String
    var mergeCommit: Commit?

    struct Commit: Decodable, Sendable, Equatable {
        var oid: GitCommit.SHA
    }

    static let jsonFields = "number,title,url,headRefName,mergeCommit"

    /// The newest 100 pull requests merged into `base`, from `gh`.
    static func list(base: String, repoPath: String) throws -> [MergedPullRequest] {
        let data = try GitHubCLI.run(
            ["pr", "list", "--state", "merged", "--base", base, "--limit", "100", "--json", jsonFields], in: repoPath)
        return try JSONDecoder().decode([MergedPullRequest].self, from: data)
    }
}

/// Gathers what a planning job looks at, and finds whether one is due.
struct PlanningGatherer: Sendable {
    let workspace: WorkspaceConfig
    let linear: any PlanningReading
    /// The pull requests merged into a base branch in a repository.
    var mergedPullRequests: @Sendable (_ base: String, _ repoPath: String) throws -> [MergedPullRequest] = MergedPullRequest.list
    /// Whether to fetch the default branch first.
    var fetch = true

    private var repoPath: String { NSString(string: workspace.repoPath).expandingTildeInPath }

    /// What makes a job due now, given the workspace's jobs so far, or nil
    /// when nothing changed since the last: the default branch's head is not
    /// the one it looked at, or issues were completed since it ended. Asks
    /// the remote for the head and Linear for the completions, so it is
    /// cheap enough for every poll.
    func trigger(history: [PlanningRunRecord]) async throws -> PlanningTrigger? {
        guard let last = PlanningHistory.last(history) else { return .firstJob }
        guard let branch = PlanningGit.defaultBranch(repoPath: repoPath) else { throw PlanningError.noDefaultBranch(repoPath) }
        if let head = PlanningGit.head(of: branch, repoPath: repoPath), head != PlanningHistory.lastHead(history) {
            return .newCommits(head)
        }
        let completed = try await linear.completedIssues(teamIds: workspace.watchedTeams, after: last.endedAt)
        return completed.isEmpty ? nil : .completedIssues(completed)
    }

    /// The context of a job that follows the jobs in `history`: the commits
    /// after the last successful one's head and the issues completed since
    /// the last one ended, or, on the first job, those of the last
    /// `PlanningHistory.firstJobLookback`.
    func gather(history: [PlanningRunRecord], trigger: PlanningTrigger, now: Date) async throws -> PlanningContext {
        let repoPath = repoPath
        guard let branch = PlanningGit.defaultBranch(repoPath: repoPath) else { throw PlanningError.noDefaultBranch(repoPath) }
        guard let worktree = PlanningGit.worktree(of: branch, repoPath: repoPath) else {
            throw PlanningError.noWorktree(branch: branch, repoPath: repoPath)
        }
        var warnings: [String] = []
        if fetch, Git.run(["fetch", "--quiet", "origin", branch], in: repoPath) == nil {
            warnings.append("Could not fetch \(branch); the commits are those known locally")
        }
        let ref = PlanningGit.ref(of: branch, repoPath: repoPath)
        guard let head = Git.run(["rev-parse", ref], in: repoPath).map({ GitCommit.SHA(rawValue: $0) }) else {
            throw PlanningError.noHead(ref)
        }
        if let problem = PlanningGit.fastForward(worktree: worktree, to: ref) { warnings.append(problem) }
        let since = PlanningHistory.since(history)
        let lookback = now.addingTimeInterval(-PlanningHistory.firstJobLookback)
        var commits = PlanningGit.commits(repoPath: repoPath, since: since, through: ref, notBefore: lookback)

        let teamIds = workspace.watchedTeams
        let issues = try await linear.planningIssues(teamIds: teamIds)
        let teams = try await linear.planningTeams(ids: teamIds)
        let projectIds = Array(Set(issues.compactMap(\.projectId))).sorted()
        let projects = projectIds.isEmpty ? [] : try await linear.planningProjects(ids: projectIds)
        let completed = try await linear.completedIssues(
            teamIds: teamIds, after: PlanningHistory.last(history)?.endedAt ?? lookback)

        var pullRequests: [GitCommit.SHA: PlanningPullRequest] = [:]
        if !commits.isEmpty {
            do {
                for merged in try mergedPullRequests(branch, repoPath) {
                    guard let oid = merged.mergeCommit?.oid else { continue }
                    pullRequests[oid] = PlanningPullRequest(
                        number: merged.number, title: merged.title, url: merged.url, headRefName: merged.headRefName)
                }
            } catch {
                warnings.append("Could not list the pull requests merged into \(branch): \(error)")
            }
        }
        let keys = Set(teams.map(\.key) + issues.map(\.teamKey))
        for index in commits.indices {
            let pullRequest = pullRequests[commits[index].sha]
            commits[index].pullRequest = pullRequest
            commits[index].issues = PlanningGit.identifiers(
                in: [pullRequest?.headRefName, pullRequest?.title, commits[index].subject, commits[index].body].compactMap { $0 },
                keys: keys)
        }

        var spec: PlanningSpec?
        if let id = workspace.planning.specDocumentId, let url = workspace.planning.specDocumentURL {
            let text = try await linear.spec(of: .document(id))
            spec = PlanningSpec(id: id, url: url, content: text.content, updatedAt: text.updatedAt)
        }

        return PlanningContext(
            workspace: workspace.name, trigger: trigger.description, defaultBranch: branch, worktreePath: worktree,
            head: head, since: since, commits: commits, completedIssues: completed, issues: issues, projects: projects,
            teams: teams, spec: spec, warnings: warnings
        )
    }
}
