import Foundation


/// Matches issues in a started state to the pull requests opened from their
/// branches, for issues the daemon does not follow through a run or a merge
/// watch: work done by hand, or by agents from before a state reset. Their
/// pull requests are linked, and a merged one completes the issue.
enum StartedIssueSweep {
    struct Item: Equatable {
        let issue: LinearIssueStatus
        let pullRequests: [PullRequest]
        /// The merged pull request that completes the issue, when there is one.
        let merged: PullRequest?
    }

    static func plan(
        issues: [LinearIssueStatus], pullRequests: [PullRequest], excluding tracked: Set<String>
    ) -> [Item] {
        let byBranch = Dictionary(grouping: pullRequests.filter { $0.headRefName != nil }) { $0.headRefName! }
        return issues.compactMap { issue in
            guard !tracked.contains(issue.id), let pullRequests = byBranch[issue.branchName] else { return nil }
            return Item(issue: issue, pullRequests: pullRequests, merged: completingMerge(issue, pullRequests))
        }
    }

    /// Started issues whose agent the Claude usage limit stopped before the
    /// daemon could pause it, as a daemon from before the pause did: issues it
    /// processed and follows through no run or merge watch, with no pull
    /// request from their branch, whose last agent log ends at the limit.
    static func stoppedAtUsageLimit(
        issues: [LinearIssueStatus], pullRequests: [PullRequest], processed: Set<LinearIssue.ID>, tracked: Set<LinearIssue.ID>,
        stopped: (LinearIssue.Identifier) -> Bool
    ) -> [LinearIssueStatus] {
        let branches = Set(pullRequests.compactMap(\.headRefName))
        return issues.filter { issue in
            let id = LinearIssue.ID(rawValue: issue.id)
            return processed.contains(id) && !tracked.contains(id) && !branches.contains(issue.branchName)
                && stopped(issue.identifier)
        }
    }

    /// The merge that completes the issue: none while a pull request is still
    /// open, as for follow-up work, nor one from before the issue last moved
    /// into a started state, so an issue reopened after its merge is left
    /// started rather than completed again each poll.
    static func completingMerge(_ issue: LinearIssueStatus, _ pullRequests: [PullRequest]) -> PullRequest? {
        guard !pullRequests.contains(where: { $0.state == .open }) else { return nil }
        let merges = pullRequests.filter { $0.state == .merged }
        guard let latest = merges.max(by: { ($0.mergedAt ?? .distantPast) < ($1.mergedAt ?? .distantPast) })
        else { return nil }
        if let startedAt = issue.startedAt, let mergedAt = latest.mergedAt, mergedAt < startedAt { return nil }
        return latest
    }
}

/// The agents recovered after the Claude usage limit stopped them, by issue
/// ID, with when each one's log was last written, so each log is recovered
/// once.
struct UsageLimitRecoveries {
    private var logs: [LinearIssue.ID: Date] = [:]

    /// Whether to recover `issueId`'s agent now, recording it when so.
    mutating func claim(issueId: LinearIssue.ID, logModified: Date?) -> Bool {
        guard let logModified, logs[issueId] != logModified else { return false }
        logs[issueId] = logModified
        return true
    }
}
