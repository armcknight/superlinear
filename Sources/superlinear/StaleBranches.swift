import Foundation

/// A local branch, with its worktree if it has one, that no longer needs to
/// be kept: its pull request merged or closed, or its worktree's agent ended
/// without opening one. `work finish <branch>` removes both.
struct StaleBranch: Sendable, Equatable {
    enum Reason: Sendable, Equatable {
        case merged(PullRequest.Number)
        case closed(PullRequest.Number)
        case noPullRequest
    }

    let branch: String
    let reason: Reason
    let hasWorktree: Bool
    let lastCommit: Date?
    /// Commits lost if the branch goes: for a merged or closed pull request,
    /// those made after its head; otherwise those no remote branch has.
    var unpushedCommits: Int
    /// The pull request's head commit, if it has a pull request.
    var pullRequestHead: String? = nil

    /// Merged first, then closed, then those without a pull request.
    var rank: Int {
        switch reason {
        case .merged: 0
        case .closed: 1
        case .noPullRequest: 2
        }
    }

    func detail(now: Date = Date()) -> String {
        var parts: [String]
        switch reason {
        case .merged(let number): parts = ["merged in #\(number)"]
        case .closed(let number): parts = ["#\(number) closed without a merge"]
        case .noPullRequest: parts = ["no pull request"]
        }
        if hasWorktree { parts.append("worktree") }
        if let lastCommit {
            let days = Int(now.timeIntervalSince(lastCommit) / 86_400)
            parts.append(days < 1 ? "last commit today" : "last commit \(days)d ago")
        }
        if unpushedCommits > 0 { parts.append("\(unpushedCommits) unpushed commit\(unpushedCommits == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

enum StaleBranches {
    struct LocalBranch: Sendable, Equatable {
        let name: String
        let lastCommit: Date?
        /// The worktree it is checked out in, if any.
        let worktree: String?
    }

    /// The stale branches among `branches`. `protected` are never stale, such
    /// as the base branch; `inFlight` are branches of agents running or
    /// queued. A branch without a pull request counts only with a worktree
    /// under `worktreesRoot`, where `work start` makes them, as one without
    /// may be work of your own.
    static func find(
        branches: [LocalBranch], pullRequests: [PullRequest], protected: Set<String>, inFlight: Set<String>,
        worktreesRoot: String
    ) -> [StaleBranch] {
        branches.compactMap { branch -> StaleBranch? in
            guard !protected.contains(branch.name), !inFlight.contains(branch.name) else { return nil }
            let reason: StaleBranch.Reason
            var head: String?
            switch PullRequest.best(for: branch.name, among: pullRequests) {
            case let pullRequest? where pullRequest.state == .open: return nil
            case let pullRequest? where pullRequest.state == .merged:
                reason = .merged(pullRequest.number)
                head = pullRequest.headRefOid
            case let pullRequest?:
                reason = .closed(pullRequest.number)
                head = pullRequest.headRefOid
            case nil:
                guard branch.worktree?.hasPrefix(worktreesRoot + "/") == true else { return nil }
                reason = .noPullRequest
            }
            return StaleBranch(
                branch: branch.name, reason: reason, hasWorktree: branch.worktree != nil,
                lastCommit: branch.lastCommit, unpushedCommits: 0, pullRequestHead: head
            )
        }.sorted { a, b in
            a.rank == b.rank ? a.branch.localizedStandardCompare(b.branch) == .orderedAscending : a.rank < b.rank
        }
    }

    /// The repository's local branches with their worktrees and last commits,
    /// from git. Counting unpushed commits takes a git call per branch, so it
    /// is left to `countUnpushed`, for the stale ones only.
    static func localBranches(repoPath: String) -> [LocalBranch] {
        guard let refs = Git.run(
            ["for-each-ref", "refs/heads", "--format=%(refname:short)%09%(committerdate:unix)"], in: repoPath)
        else { return [] }
        let worktrees = worktreeBranches(Git.run(["worktree", "list", "--porcelain"], in: repoPath) ?? "")
        return refs.split(separator: "\n").map { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            let name = String(fields[0])
            let date = fields.count > 1 ? TimeInterval(fields[1]).map(Date.init(timeIntervalSince1970:)) : nil
            return LocalBranch(name: name, lastCommit: date, worktree: worktrees[name])
        }
    }

    /// Each checked-out branch's worktree, from `git worktree list --porcelain`.
    static func worktreeBranches(_ porcelain: String) -> [String: String] {
        var result: [String: String] = [:]
        for block in porcelain.components(separatedBy: "\n\n") {
            var path: String?
            var branch: String?
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
                if line.hasPrefix("branch refs/heads/") { branch = String(line.dropFirst("branch refs/heads/".count)) }
            }
            if let path, let branch { result[branch] = path }
        }
        return result
    }

    /// Branches never stale: the one checked out in the main checkout and the
    /// remote's default.
    static func protectedBranches(repoPath: String) -> Set<String> {
        var names: Set<String> = []
        if let current = Git.run(["branch", "--show-current"], in: repoPath), !current.isEmpty { names.insert(current) }
        if let head = Git.run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: repoPath) {
            names.insert(String(head.dropFirst("origin/".count)))
        }
        return names
    }

    /// `stale` with each branch's commits that would be lost counted. A
    /// squash merge leaves a merged branch's commits on no remote branch,
    /// though their changes are in the base, so a branch with a pull request
    /// counts only the commits after its head; that head must be known
    /// locally, or no remote branch may have them.
    static func countUnpushed(_ stale: [StaleBranch], repoPath: String) -> [StaleBranch] {
        stale.map { branch in
            let known = branch.pullRequestHead.flatMap { head in
                Git.run(["cat-file", "-e", "\(head)^{commit}"], in: repoPath).map { _ in head }
            }
            let arguments = known.map { ["rev-list", "--count", "\($0)..\(branch.branch)"] }
                ?? ["rev-list", "--count", branch.branch, "--not", "--remotes"]
            var counted = branch
            counted.unpushedCommits = Git.run(arguments, in: repoPath).flatMap { Int($0) } ?? 0
            return counted
        }
    }
}
