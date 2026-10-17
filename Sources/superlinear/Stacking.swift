import Foundation
import Tagged

/// The pull request an issue's work is stacked on: the open pull request of
/// its one unmerged blocker. The issue's branch starts from this branch, and
/// its pull request targets it. Kept with the run and the merge watch.
struct StackBase: Codable, Sendable, Equatable {
    enum DepthTag {}
    /// How many pull requests a stack holds, the bottom one included.
    typealias Depth = Tagged<DepthTag, Int>

    /// The blocker the pull request belongs to.
    var identifier: LinearIssue.Identifier
    var branch: GitBranch.Name
    var number: PullRequest.Number
    var url: String
    /// How deep the lower pull request is: 1 for one on the default branch.
    var depth: Depth
    /// The lower branch's head last merged into the stacked branch, so a push
    /// to the lower branch is seen. Absent until the branch is created.
    var baseHead: GitCommit.SHA?
    /// Set when the lower pull request was closed without a merge and the
    /// daemon made the stacked pull request a draft, until the lower one is
    /// open again or the owner retargets the upper one.
    var drafted: Bool?

    init(
        identifier: LinearIssue.Identifier, branch: GitBranch.Name, number: PullRequest.Number, url: String, depth: Depth,
        baseHead: GitCommit.SHA?, drafted: Bool?
    ) {
        self.identifier = identifier
        self.branch = branch
        self.number = number
        self.url = url
        self.depth = depth
        self.baseHead = baseHead
        self.drafted = drafted
    }
}

/// What a poll does to keep a stacked pull request current with the one
/// below it.
enum StackAction: Equatable {
    /// The lower branch is where it was.
    case none
    /// The lower branch moved: merge it in at `head` and push.
    case restack(head: GitCommit.SHA)
    /// The lower pull request merged. Its pull request now targets `base`,
    /// or should: GitHub retargets it when the lower branch is deleted, and
    /// the daemon does when it is not. Then `base` is merged in, so the diff
    /// holds only the upper pull request's own changes.
    case lowerMerged(base: GitBranch.Name, retarget: Bool)
    /// The lower pull request was closed without a merge: the upper one
    /// becomes a draft, for the owner to decide.
    case lowerClosed
    /// The lower pull request is open again after a close: the upper one
    /// leaves draft.
    case lowerReopened
}

/// Why an issue cannot stack on its blocker's pull request.
enum NotStackable: Error, Equatable, CustomStringConvertible {
    case noPullRequest
    case draft
    case ciNotPassing(ReviewablePullRequest.CheckState)
    case tooDeep(StackBase.Depth)

    var description: String {
        switch self {
        case .noPullRequest: "its blocker has no open pull request"
        case .draft: "its blocker's pull request is a draft"
        case .ciNotPassing(let state): "its blocker's pull request has \(state.rawValue)"
        case .tooDeep(let depth): "the stack would be \(depth) deep"
        }
    }
}

enum Stacking {
    /// The base an issue may stack on: its blocker's pull request, when the
    /// blocker's agent has ended and the pull request is open, not a draft,
    /// with CI passing, and the stack stays within `maxDepth`.
    static func base(
        on blocker: PendingMerge, pullRequest: PullRequest?, maxDepth: StackBase.Depth
    ) -> Result<StackBase, NotStackable> {
        guard let pullRequest, pullRequest.state == .open else { return .failure(.noPullRequest) }
        guard pullRequest.isDraft != true else { return .failure(.draft) }
        let checks = ReviewablePullRequest.checkState(of: pullRequest.statusCheckRollup)
        guard checks == .passing else { return .failure(.ciNotPassing(checks)) }
        let depth = blocker.stackDepth + 1
        guard depth <= maxDepth else { return .failure(.tooDeep(depth)) }
        return .success(StackBase(
            identifier: blocker.identifier, branch: GitBranch.Name(rawValue: blocker.branchName), number: pullRequest.number,
            url: pullRequest.url, depth: blocker.stackDepth, baseHead: pullRequest.headRefOid.map { GitCommit.SHA(rawValue: $0) },
            drafted: nil
        ))
    }

    /// What to do for a stacked pull request this poll. `lower` is what the
    /// lower branch has on GitHub, `lowerHead` the lower branch's head on the
    /// remote, nil when it is gone.
    static func action(
        for stack: StackBase, pullRequest: PullRequest, lower: [PullRequest], lowerHead: GitCommit.SHA?,
        defaultBranch: GitBranch.Name
    ) -> StackAction {
        // The owner moved it off the lower branch: treat the lower one as
        // merged into the new base, which is now the branch to keep up with.
        if let base = pullRequest.baseRefName, base != stack.branch.rawValue {
            return .lowerMerged(base: GitBranch.Name(rawValue: base), retarget: false)
        }
        switch MergeStatus.of(lower) {
        case .merged(let merged):
            return .lowerMerged(base: merged.baseRefName.map { GitBranch.Name(rawValue: $0) } ?? defaultBranch, retarget: true)
        case .closed:
            return stack.drafted == true ? .none : .lowerClosed
        case .missing:
            // Not in the listing, which holds the newest 1,000: say nothing
            // rather than draft the upper one over a listing gap.
            return .none
        case .open:
            if stack.drafted == true { return .lowerReopened }
            guard let lowerHead, lowerHead != stack.baseHead else { return .none }
            return .restack(head: lowerHead)
        }
    }

    /// Creates `branch` from the head of `base` on `origin`, fetched first,
    /// and returns that head. Nil, and nothing done, when the branch exists
    /// already, as after a resume.
    static func createBranch(_ branch: String, from base: GitBranch.Name, repoPath: String) throws -> GitCommit.SHA? {
        if Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)^{commit}"], in: repoPath) != nil {
            return nil
        }
        try run(["fetch", "--quiet", "origin", base.rawValue], in: repoPath)
        try run(["branch", branch, "refs/remotes/origin/\(base)"], in: repoPath)
        return GitCommit.SHA(rawValue: try output(["rev-parse", "--verify", "refs/remotes/origin/\(base)^{commit}"], in: repoPath))
    }

    enum MergeOutcome: Equatable {
        /// The base, at `baseHead`, was merged in and the branch pushed, to
        /// `head`.
        case merged(head: GitCommit.SHA, baseHead: GitCommit.SHA)
        /// The branch had the base, at `baseHead`, already.
        case upToDate(baseHead: GitCommit.SHA)
        /// The merge conflicted; it was aborted, and the worktree is as it was.
        case conflicted
    }

    /// Merges `origin/<base>` into the branch checked out at `worktree`
    /// with a merge commit, never a rebase, and pushes it. A merge that
    /// conflicts is aborted. The worktree must be clean, as an agent leaves it.
    static func mergeBase(_ base: GitBranch.Name, into branch: String, worktree: String) throws -> MergeOutcome {
        try run(["fetch", "--quiet", "origin", base.rawValue], in: worktree)
        let status = try output(["status", "--porcelain", "--untracked-files=no"], in: worktree)
        guard status.isEmpty else {
            throw StackingError("the worktree at \(worktree) has uncommitted changes")
        }
        let baseHead = GitCommit.SHA(rawValue: try output(["rev-parse", "--verify", "refs/remotes/origin/\(base)^{commit}"], in: worktree))
        if Git.run(["merge-base", "--is-ancestor", baseHead.rawValue, "HEAD"], in: worktree) != nil {
            return .upToDate(baseHead: baseHead)
        }
        let merge = Git.result(
            ["merge", "--no-ff", "--no-edit", "-m", "Merge \(base) into \(branch)", "refs/remotes/origin/\(base)"],
            in: worktree)
        guard merge.status == 0 else {
            _ = Git.result(["merge", "--abort"], in: worktree)
            return .conflicted
        }
        try run(["push", "--quiet", "origin", "HEAD:refs/heads/\(branch)"], in: worktree)
        return .merged(head: GitCommit.SHA(rawValue: try output(["rev-parse", "HEAD"], in: worktree)), baseHead: baseHead)
    }

    private static func run(_ arguments: [String], in directory: String) throws {
        _ = try output(arguments, in: directory)
    }

    private static func output(_ arguments: [String], in directory: String) throws -> String {
        let result = Git.result(arguments, in: directory)
        guard result.status == 0 else {
            throw StackingError("`git \(arguments.joined(separator: " "))` exited \(result.status): \(result.output)")
        }
        return result.output
    }
}

struct StackingError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension PendingMerge {
    /// How deep the issue's pull request is: 1 for one on the default branch.
    var stackDepth: StackBase.Depth { (stack?.depth ?? 0) + 1 }
}

extension AgentRun {
    var stackDepth: StackBase.Depth { (stack?.depth ?? 0) + 1 }
}
