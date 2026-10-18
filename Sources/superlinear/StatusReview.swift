import Foundation
import Tagged

/// An open pull request waiting on the owner, with what it holds back.
struct WaitingPullRequest: Sendable, Equatable {
    var pullRequest: ReviewablePullRequest
    /// The pull request it is stacked on, if any.
    var stackedOn: PullRequest.Number?
    /// The open issues its issues block, directly and indirectly.
    var blockedIssues: Set<LinearIssue.Identifier> = []
}

/// The parts of `superlinear status` that ask for the owner's attention:
/// what waits on them, what the daemon did on its own, and what puts the
/// work at risk.
enum StatusReview {
    /// How far back "Done autonomously" looks when `--since` is not given.
    static let defaultSince: TimeInterval = 24 * 60 * 60

    /// A duration as `--since` takes it: a number and a unit, `s`, `m`, `h`
    /// or `d`, as in `24h` or `7d`. Nil when `text` is not one.
    static func duration(_ text: String) -> TimeInterval? {
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let unit = text.last, let amount = Double(text.dropLast()), amount > 0 else { return nil }
        switch unit {
        case "s": return amount
        case "m": return amount * 60
        case "h": return amount * 60 * 60
        case "d": return amount * 24 * 60 * 60
        default: return nil
        }
    }

    /// The daemon's activity since `since`, and the proposals applied
    /// automatically since then, oldest first.
    static func done(_ state: WorkspaceState, since: Date, now: Date) -> [String] {
        struct Line {
            var time: Date
            var text: String
        }
        var lines = state.activity.filter { $0.time >= since }.map { Line(time: $0.time, text: $0.rendered) }
        for proposal in state.proposals where proposal.trust == .auto && proposal.status == .applied {
            guard let decided = proposal.decidedAt, decided >= since else { continue }
            lines.append(Line(time: decided, text: "applied automatically: \(proposal.kind.rawValue) → \(targetName(proposal.target))"))
        }
        return lines.sorted { $0.time < $1.time }.map { "\(StatusTime.rendered($0.time, now: now))  \($0.text)" }
    }

    static func targetName(_ target: ProposalTarget) -> String {
        "\(target.kind.rawValue) \(target.name ?? target.rawID)"
    }

    /// The open issues each issue blocks, directly and through the issues it
    /// blocks, by identifier, from the daemon's blocked issues.
    static func blockedIssues(
        _ blocked: [LinearIssue.ID: WaitingIssue]
    ) -> [LinearIssue.Identifier: Set<LinearIssue.Identifier>] {
        var blockedBy: [LinearIssue.Identifier: Set<LinearIssue.Identifier>] = [:]
        for issue in blocked.values {
            for blocker in issue.blockers { blockedBy[blocker, default: []].insert(issue.identifier) }
        }
        var result: [LinearIssue.Identifier: Set<LinearIssue.Identifier>] = [:]
        for start in blockedBy.keys {
            var seen: Set<LinearIssue.Identifier> = []
            var next = Array(blockedBy[start] ?? [])
            while let identifier = next.popLast() {
                guard identifier != start, seen.insert(identifier).inserted else { continue }
                next += blockedBy[identifier] ?? []
            }
            result[start] = seen
        }
        return result
    }

    /// Open pull requests ready for review, by stack, the stacks holding back
    /// the most work first: the issues their pull requests block, and the
    /// pull requests stacked on the bottom one. Each stack is listed bottom
    /// first. Drafts, and pull requests an agent is working on, are left out.
    static func waitingOnYou(
        _ pullRequests: [ReviewablePullRequest], state: WorkspaceState
    ) -> [WaitingPullRequest] {
        let busy = Set(state.inFlight.values.compactMap { $0.review?.url ?? $0.conflict?.url })
        let ready = pullRequests.filter { !$0.isDraft && !busy.contains($0.url) }
        let blocked = blockedIssues(state.blocked)
        let byHead = Dictionary(ready.map { ($0.headRefName, $0) }, uniquingKeysWith: { a, _ in a })
        func parent(_ pullRequest: ReviewablePullRequest) -> ReviewablePullRequest? {
            pullRequest.baseRefName.flatMap { byHead[$0] }.flatMap { $0.number == pullRequest.number ? nil : $0 }
        }
        var children: [PullRequest.Number: [ReviewablePullRequest]] = [:]
        for pullRequest in ready {
            if let parent = parent(pullRequest) { children[parent.number, default: []].append(pullRequest) }
        }
        func waiting(_ pullRequest: ReviewablePullRequest, stackedOn: PullRequest.Number?) -> WaitingPullRequest {
            let blockedIssues = pullRequest.issueIdentifiers.reduce(into: Set()) { $0.formUnion(blocked[$1] ?? []) }
            return WaitingPullRequest(pullRequest: pullRequest, stackedOn: stackedOn, blockedIssues: blockedIssues)
        }

        /// A stack of pull requests, bottom first.
        struct Stack {
            var items: [WaitingPullRequest]
            var bottom: PullRequest.Number { items[0].pullRequest.number }
            /// The work it holds back: the open issues its pull requests
            /// block, and the pull requests stacked on the bottom one.
            var weight: Int {
                items.reduce(into: Set()) { $0.formUnion($1.blockedIssues) }.count + items.count - 1
            }
        }
        var stacks: [Stack] = []
        var placed: Set<PullRequest.Number> = []
        for root in ready.sorted(by: { $0.number < $1.number }) where parent(root) == nil {
            var items: [WaitingPullRequest] = []
            var next = [waiting(root, stackedOn: nil)]
            while !next.isEmpty {
                let item = next.removeFirst()
                let number = item.pullRequest.number
                guard placed.insert(number).inserted else { continue }
                items.append(item)
                let above = (children[number] ?? []).sorted { $0.number < $1.number }
                next = above.map { waiting($0, stackedOn: number) } + next
            }
            stacks.append(Stack(items: items))
        }
        // Pull requests in a cycle of bases have no bottom; list them alone.
        for pullRequest in ready where !placed.contains(pullRequest.number) {
            stacks.append(Stack(items: [waiting(pullRequest, stackedOn: nil)]))
        }
        return stacks.sorted { $0.weight == $1.weight ? $0.bottom < $1.bottom : $0.weight > $1.weight }.flatMap(\.items)
    }

    /// The line about the proposals waiting in Linear, and a line for each.
    static func proposalsWaiting(_ proposals: [Proposal]) -> [String] {
        let waiting = proposals.filter(\.isPosted).sorted { ($0.post?.postedAt ?? .distantPast) < ($1.post?.postedAt ?? .distantPast) }
        guard !waiting.isEmpty else { return [] }
        var lines = ["\(waiting.count) proposal\(waiting.count == 1 ? "" : "s") waiting in Linear, labeled \"\(ProposalEngine.proposedLabel)\""]
        for proposal in waiting {
            let where_ = proposal.post?.issueIdentifier ?? targetName(proposal.target)
            lines.append("  \(proposal.kind.rawValue) on \(where_)" + (proposal.post?.url.map { ": \($0)" } ?? ""))
        }
        return lines
    }

    struct RateLimit: Sendable, Equatable {
        /// GraphQL points, which GitHub budgets by the hour.
        typealias Points = Tagged<RateLimit, Int>

        var remaining: Points
        var limit: Points
        var reset: Date
    }

    /// The share of the rate limit left under which the status warns.
    static let rateLimitWarning = 0.2

    /// The GraphQL limit, which `gh pr list` spends, from `gh api rate_limit`.
    static func decodeRateLimit(_ data: Data) throws -> RateLimit? {
        struct Response: Decodable {
            struct Resources: Decodable { let graphql: Limit? }
            struct Limit: Decodable { let limit: Int; let remaining: Int; let reset: TimeInterval }
            let resources: Resources
        }
        guard let limit = try JSONDecoder().decode(Response.self, from: data).resources.graphql else { return nil }
        return RateLimit(remaining: .init(rawValue: limit.remaining), limit: .init(rawValue: limit.limit), reset: Date(timeIntervalSince1970: limit.reset))
    }

    /// The latest completed run on `defaultBranch` among `runs`, as `gh run
    /// list` reports them newest first.
    static func latestRun(_ runs: [WorkflowRun], on defaultBranch: String) -> WorkflowRun? {
        runs.first { $0.headBranch == defaultBranch && $0.status == "completed" }
    }

    /// What puts the work at risk: the active pauses and what they hold
    /// back, CI failing on the default branch, and a low GitHub rate limit.
    static func risks(
        defaultBranch: String?, latestRun: WorkflowRun?, rateLimit: RateLimit?, pauses: Pauses, now: Date
    ) -> [String] {
        var risks = pauses.risks(now: now)
        // A run the spending limit stopped is listed with the pause.
        let stopped = pauses.spendingLimit?.branches ?? []
        if let defaultBranch, !stopped.contains(defaultBranch), let run = latestRun, run.status == "completed",
           let conclusion = run.conclusion, !conclusion.isPassing {
            let name = run.workflowName.map { " (\($0))" } ?? ""
            risks.append("CI \(conclusion.rawValue) on \(defaultBranch)\(name)" + (run.url.map { ": \($0)" } ?? ""))
        }
        if let rateLimit, rateLimit.limit > 0,
           Double(rateLimit.remaining.rawValue) < Double(rateLimit.limit.rawValue) * rateLimitWarning {
            risks.append("GitHub rate limit: \(rateLimit.remaining) of \(rateLimit.limit) left, "
                + "resets \(StatusTime.rendered(rateLimit.reset, now: now))")
        }
        // TODO: SPL-13 adds milestone forecasts; list milestones forecast to
        // be late here.
        return risks
    }

    /// The pauses active for a workspace, which the risks list with the work
    /// they hold back.
    struct Pauses: Sendable, Equatable {
        /// The pause of every Claude session at the usage limit.
        var claude: ClaudePause?
        /// The issues whose sessions it holds back, in the workspace.
        var waiting: [LinearIssue.Identifier]
        /// The workspace's CI runs the GitHub Actions spending limit stopped.
        var spendingLimit: SpendingLimitStop?

        /// The pauses in the state file for `workspace`.
        init(state: State, workspace: String, now: Date) {
            let queued = state.workspaces[workspace]?.inFlight.values.filter(\.isQueued) ?? []
            self.init(
                claude: state.claudePause.flatMap { $0.isOver(now: now) ? nil : $0 },
                waiting: queued.map(\.identifier).sorted { $0.sortsBefore($1) },
                spendingLimit: state.workspaces[workspace]?.spendingLimit)
        }

        init(claude: ClaudePause?, waiting: [LinearIssue.Identifier], spendingLimit: SpendingLimitStop?) {
            self.claude = claude
            self.waiting = waiting
            self.spendingLimit = spendingLimit
        }

        func risks(now: Date) -> [String] {
            var risks: [String] = []
            if let claude {
                let held = waiting.isEmpty ? "holds back no session here" : "holds back \(list(waiting))"
                risks.append("Claude usage limit: sessions paused until \(StatusTime.clock(claude.until.rawValue, now: now)), "
                    + "next check \(StatusTime.clock(claude.nextCheckAt, now: now)); \(held)")
            }
            if let stop = spendingLimit {
                risks.append("GitHub Actions spending limit: CI not started since \(StatusTime.clock(stop.since, now: now)) "
                    + "on \(stop.branches.sorted().joined(separator: ", ")); one stopped run is rerun each hour")
            }
            return risks
        }
    }

    static func list(_ identifiers: [LinearIssue.Identifier]) -> String {
        identifiers.map(\.rawValue).joined(separator: ", ")
    }
}
