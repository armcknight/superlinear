import Foundation

/// An open issue as the planning job sees it.
struct PlanningIssue: Codable, Sendable, Equatable {
    var id: LinearIssue.ID
    var identifier: LinearIssue.Identifier
    var title: String
    var description: String
    var stateName: String
    var stateType: LinearStateType
    /// 0 for no priority, then 1 (urgent) to 4 (low).
    var priority: Double?
    var teamId: LinearTeam.ID
    var teamKey: String
    var projectId: LinearProject.ID?
    var projectName: String?
    var milestone: String?
    var labels: [String]
    var relations: [PlanningRelation]
    var updatedAt: Date

    var createdBySuperlinear: Bool { labels.contains { $0.caseInsensitiveCompare(ProposalEngine.label) == .orderedSame } }
    var handsOff: Bool { labels.contains { $0.caseInsensitiveCompare(ProposalEngine.handsOffLabel) == .orderedSame } }

    /// The text an edit replaces: the whole description of an issue
    /// superlinear created, otherwise its managed block.
    var editableText: String {
        createdBySuperlinear ? description : ManagedBlock.contents(of: description) ?? ""
    }
}

/// A relation between an open issue and another.
struct PlanningRelation: Codable, Sendable, Equatable {
    /// `blocks`, `duplicate`, `related` or `similar`.
    var type: String
    var identifier: LinearIssue.Identifier
    /// Whether the issue is the relation's subject, as the one that blocks,
    /// rather than its object.
    var outgoing: Bool

    var rendered: String {
        switch (type, outgoing) {
        case ("blocks", true): "blocks \(identifier)"
        case ("blocks", false): "blocked by \(identifier)"
        case ("duplicate", true): "duplicate of \(identifier)"
        case ("duplicate", false): "duplicated by \(identifier)"
        default: "\(type) to \(identifier)"
        }
    }
}

struct PlanningProject: Codable, Sendable, Equatable {
    var id: LinearProject.ID
    var name: String
    var content: String
    var updatedAt: Date
    var milestones: [Milestone]

    struct Milestone: Codable, Sendable, Equatable {
        var name: String
        var targetDate: String?
    }
}

struct PlanningTeam: Codable, Sendable, Equatable {
    var id: LinearTeam.ID
    var key: String
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
    var sha: String
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
    var defaultBranch: String
    var worktreePath: String
    /// The default branch's head on the remote, or locally when there is none.
    var head: String
    /// The head the last job looked at, when there was one.
    var since: String?
    /// The default branch's commits after `since`, newest first.
    var commits: [PlanningCommit]
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
        let short = { (sha: String) in String(sha.prefix(7)) }
        guard let oldest = commits.last else { return short(head) }
        return "\(short(since ?? oldest.sha))..\(short(head))"
    }
}

/// The reads in Linear that the planning job needs. `LinearClient` does them
/// for real; tests stand in for it.
protocol PlanningReading: Sendable {
    /// Open issues in the teams, or in every team when `teamIds` is empty.
    func planningIssues(teamIds: [String]) async throws -> [PlanningIssue]
    func planningProjects(ids: [LinearProject.ID]) async throws -> [PlanningProject]
    /// The teams with these IDs, or every team when `ids` is empty.
    func planningTeams(ids: [String]) async throws -> [PlanningTeam]
    func spec(of target: ProposalTarget) async throws -> SpecText
}

enum PlanningError: Error, CustomStringConvertible {
    case noDefaultBranch(String)
    case noWorktree(branch: String, repoPath: String)
    case noHead(String)
    case alreadyRunning(String)
    case noOutput(String)

    var description: String {
        switch self {
        case .noDefaultBranch(let repoPath): "Could not find the default branch of \(repoPath)"
        case .noWorktree(let branch, let repoPath): "No worktree of \(repoPath) has \(branch) checked out"
        case .noHead(let ref): "Could not read the head of \(ref)"
        case .alreadyRunning(let detail): "A planning job is already running: \(detail)"
        case .noOutput(let path): "The session wrote no proposals file at \(path)"
        }
    }
}

/// The git reads the planning job makes in the repository.
enum PlanningGit {
    /// The branch `origin/HEAD` points at, or else `main` or `master`,
    /// whichever exists.
    static func defaultBranch(repoPath: String) -> String? {
        if let ref = Git.run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: repoPath), ref.hasPrefix("origin/") {
            return String(ref.dropFirst("origin/".count))
        }
        return ["main", "master"].first { Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\($0)"], in: repoPath) != nil }
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
    static func commits(repoPath: String, since: String?, through ref: String, notBefore: Date) -> [PlanningCommit] {
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
                sha: fields[0], author: fields[1], date: date, subject: fields[3],
                body: fields[4].trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// The identifiers of issues in teams with `keys` that `texts` name, as
    /// `SPL-11` or a branch's `spl-11`, in the order first named.
    static func identifiers(in texts: [String], keys: Set<String>) -> [LinearIssue.Identifier] {
        let keys = Set(keys.map { $0.uppercased() })
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
        var oid: String
    }

    static let jsonFields = "number,title,url,headRefName,mergeCommit"

    /// The newest 100 pull requests merged into `base`, from `gh`.
    static func list(base: String, repoPath: String) throws -> [MergedPullRequest] {
        let data = try GitHubCLI.run(
            ["pr", "list", "--state", "merged", "--base", base, "--limit", "100", "--json", jsonFields], in: repoPath)
        return try JSONDecoder().decode([MergedPullRequest].self, from: data)
    }
}

/// Gathers what a planning job looks at.
struct PlanningGatherer: Sendable {
    let workspace: WorkspaceConfig
    let linear: any PlanningReading
    /// The pull requests merged into a base branch in a repository.
    var mergedPullRequests: @Sendable (_ base: String, _ repoPath: String) throws -> [MergedPullRequest] = MergedPullRequest.list
    /// Whether to fetch the default branch first.
    var fetch = true

    /// The context of a job that starts from the head `since`, or, on the
    /// first job, from the commits of the last `PlanningSchedule.interval`.
    func gather(since: String?, now: Date = Date()) async throws -> PlanningContext {
        let repoPath = NSString(string: workspace.repoPath).expandingTildeInPath
        guard let branch = PlanningGit.defaultBranch(repoPath: repoPath) else { throw PlanningError.noDefaultBranch(repoPath) }
        guard let worktree = PlanningGit.worktree(of: branch, repoPath: repoPath) else {
            throw PlanningError.noWorktree(branch: branch, repoPath: repoPath)
        }
        var warnings: [String] = []
        if fetch, Git.run(["fetch", "--quiet", "origin", branch], in: repoPath) == nil {
            warnings.append("Could not fetch \(branch); the commits are those known locally")
        }
        let ref = PlanningGit.ref(of: branch, repoPath: repoPath)
        guard let head = Git.run(["rev-parse", ref], in: repoPath) else { throw PlanningError.noHead(ref) }
        if let problem = PlanningGit.fastForward(worktree: worktree, to: ref) { warnings.append(problem) }
        var commits = PlanningGit.commits(
            repoPath: repoPath, since: since, through: ref, notBefore: now.addingTimeInterval(-PlanningSchedule.interval))

        let issues = try await linear.planningIssues(teamIds: workspace.teamIds)
        let teams = try await linear.planningTeams(ids: workspace.teamIds)
        let projectIds = Array(Set(issues.compactMap(\.projectId))).sorted()
        let projects = projectIds.isEmpty ? [] : try await linear.planningProjects(ids: projectIds)

        var pullRequests: [String: PlanningPullRequest] = [:]
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
            workspace: workspace.name, defaultBranch: branch, worktreePath: worktree, head: head, since: since,
            commits: commits, issues: issues, projects: projects, teams: teams, spec: spec, warnings: warnings
        )
    }
}
