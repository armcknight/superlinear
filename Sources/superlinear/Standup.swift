import Foundation

/// An issue that needs a human, with the open issues waiting on it.
struct NeedsHumanItem: Sendable, Equatable {
    var id: LinearIssue.ID
    var issue: WaitingIssue
    /// The open issues it blocks, directly and through others.
    var blockedIssues: Set<LinearIssue.Identifier> = []
}

/// An issue in the plan for today: queued for an agent, about to be, held,
/// or in the backlog.
struct PlanItem: Sendable, Equatable {
    var issueId: LinearIssue.ID
    var identifier: LinearIssue.Identifier
    var title: String
    /// The daemon has queued it already.
    var queued = false
}

/// An open pull request waiting on the owner, with what it holds back.
struct WaitingPullRequest: Sendable, Equatable {
    var pullRequest: ReviewablePullRequest
    /// The pull request it is stacked on, if any.
    var stackedOn: PullRequest.Number?
    /// The open issues its issues block, directly and indirectly.
    var blockedIssues: Set<LinearIssue.Identifier> = []
    /// Whether its CI failed only because the GitHub Actions spending limit
    /// kept the jobs from starting.
    var ciNotStarted = false
}

/// The sections of a standup, in the order it goes through them.
enum StandupSection: Int, CaseIterable, Sendable {
    case done = 1
    case waitingOnYou
    case proposals
    case needsHuman
    case plan
    case risks

    var title: String {
        let name = switch self {
        case .done: "Done autonomously"
        case .waitingOnYou: "Waiting on you"
        case .proposals: "Proposals"
        case .needsHuman: "Needs human"
        case .plan: "Plan for today"
        case .risks: "Risks"
        }
        return "\(rawValue). \(name)"
    }
}

/// What the standup shows for one workspace.
struct StandupView: Sendable {
    var workspace: String
    var since: Date
    var now: Date
    /// Section 1: what the daemon did on its own since `since`.
    var done: [String] = []
    /// Section 2, or nil when it was not gathered.
    var waitingOnYou: [WaitingPullRequest]?
    /// Section 3: pending proposals, oldest first.
    var proposals: [Proposal] = []
    /// Section 4, most blocking first.
    var needsHuman: [NeedsHumanItem] = []
    /// Section 5: the issues agents start next, in order.
    var plan: [PlanItem] = []
    var held: [PlanItem] = []
    /// The identifiers of the issues the last standup unblocked.
    var unblocked: [LinearIssue.Identifier] = []
    /// Backlog issues that could be promoted to Todo.
    var backlog: [PlanItem] = []
    /// Section 6, or nil when it was not gathered.
    var risks: [String]?
    /// Problems that left the view incomplete.
    var warnings: [String] = []

    /// The sections `--print` shows.
    static let printedSections: [StandupSection] = [.done, .proposals, .needsHuman, .plan]
}

/// The pure rules for what each standup section holds.
enum Standup {
    /// How far back the first standup looks.
    static let firstLookBack: TimeInterval = 7 * 24 * 60 * 60

    static func since(_ standup: WorkspaceStandup, now: Date) -> Date {
        standup.lastStandupAt ?? now.addingTimeInterval(-firstLookBack)
    }

    /// Section 1: the daemon's activity since `since`, and the proposals
    /// applied automatically since then, oldest first.
    static func done(_ state: WorkspaceState, since: Date, now: Date = Date()) -> [String] {
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

    /// Section 4: the issues that need a human, those blocking the most first.
    static func needsHuman(_ state: WorkspaceState) -> [NeedsHumanItem] {
        let blocked = blockedIssues(state.blocked)
        return state.needsHuman.map { id, issue in
            NeedsHumanItem(id: id, issue: issue, blockedIssues: blocked[issue.identifier] ?? [])
        }.sorted { a, b in
            a.blockedIssues.count == b.blockedIssues.count
                ? a.issue.identifier.sortsBefore(b.issue.identifier)
                : a.blockedIssues.count > b.blockedIssues.count
        }
    }

    /// Section 2: open pull requests ready for review, by stack, the stacks
    /// holding back the most work first: the issues their pull requests block,
    /// and the pull requests stacked on the bottom one. Each stack is listed
    /// bottom first. Drafts, and pull requests an agent is working on, are
    /// left out.
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
            return WaitingPullRequest(
                pullRequest: pullRequest, stackedOn: stackedOn, blockedIssues: blockedIssues,
                ciNotStarted: pullRequest.checkState(stoppedBranches: state.spendingLimit?.branches ?? []) == .notStarted)
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

    /// Section 5: the issues agents start next, in the order the daemon will
    /// start them, and those held.
    struct Plan: Sendable, Equatable {
        var queue: [PlanItem]
        var held: [PlanItem]
    }

    /// Section 5. `upcoming` are the ready issues not yet queued, in the
    /// selection's order.
    static func plan(_ state: WorkspaceState, upcoming: [LinearIssue], standup: WorkspaceStandup) -> Plan {
        let queued = state.inFlight.values.filter(\.isFresh)
            .sorted { a, b in
                let (dateA, dateB) = (a.queuedAt ?? .distantPast, b.queuedAt ?? .distantPast)
                return dateA == dateB ? a.identifier < b.identifier : dateA < dateB
            }
            .map { PlanItem(issueId: LinearIssue.ID(rawValue: $0.issueId), identifier: $0.identifier, title: "", queued: true) }
        let queuedIds = Set(queued.map(\.issueId))
        let next = upcoming.filter { !queuedIds.contains($0.id) }
            .map { PlanItem(issueId: $0.id, identifier: $0.identifier, title: $0.title) }
        let all = standup.ordered(queued + next, id: \.issueId)
        var held = all.filter { standup.held[$0.issueId] != nil }
        let listed = Set(held.map(\.issueId))
        // Held issues the daemon has not queued, and no ready list showed.
        for (id, identifier) in standup.held.sorted(by: { $0.value < $1.value }) where !listed.contains(id) {
            held.append(PlanItem(issueId: id, identifier: identifier, title: ""))
        }
        return Plan(queue: all.filter { standup.held[$0.issueId] == nil }, held: held)
    }

    /// The issues in `blocked` whose every open blocker is in `closed`.
    static func unblocked(
        _ blocked: [LinearIssue.ID: WaitingIssue], closing closed: Set<LinearIssue.Identifier>
    ) -> [LinearIssue.Identifier] {
        blocked.values.filter { !$0.blockers.isEmpty && Set($0.blockers).isSubset(of: closed) }
            .map(\.identifier)
            .sorted { $0.sortsBefore($1) }
    }

    /// The most recent workflow run on the default branch, and GitHub's rate
    /// limit, as risks.
    struct DefaultBranchRun: Decodable, Sendable, Equatable {
        /// Where the run is, as `gh run list` reports it.
        enum Status: String, Decodable, Sendable {
            case queued, requested, waiting, pending, completed
            case inProgress = "in_progress"
            /// A status GitHub added since.
            case unknown

            init(from decoder: Decoder) throws {
                self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
            }
        }

        typealias Conclusion = WorkflowRun.Conclusion

        var status: Status
        var conclusion: Conclusion?
        var url: String?
        var workflowName: String?

        init(status: Status, conclusion: Conclusion? = nil, url: String? = nil, workflowName: String? = nil) {
            self.status = status
            self.conclusion = conclusion
            self.url = url
            self.workflowName = workflowName
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decode(Status.self, forKey: .status)
            conclusion = .parse(try container.decodeIfPresent(String.self, forKey: .conclusion))
            url = try container.decodeIfPresent(String.self, forKey: .url)
            workflowName = try container.decodeIfPresent(String.self, forKey: .workflowName)
        }

        private enum CodingKeys: String, CodingKey {
            case status, conclusion, url, workflowName
        }
    }

    struct RateLimit: Sendable, Equatable {
        var remaining: Int
        var limit: Int
        var reset: Date
    }

    /// The share of the rate limit left under which the standup warns.
    static let rateLimitWarning = 0.2

    /// Section 6.
    static func risks(
        defaultBranch: String?, latestRun: DefaultBranchRun?, rateLimit: RateLimit?,
        pauses: Pauses = Pauses(), now: Date = Date()
    ) -> [String] {
        var risks = pauses.risks(now: now)
        // A run the spending limit stopped is listed with the pause.
        let stopped = pauses.spendingLimit?.branches ?? []
        if let defaultBranch, !stopped.contains(defaultBranch), let run = latestRun, run.status == .completed,
           let conclusion = run.conclusion, !conclusion.isPassing {
            let name = run.workflowName.map { " (\($0))" } ?? ""
            risks.append("CI \(conclusion.rawValue) on \(defaultBranch)\(name)" + (run.url.map { ": \($0)" } ?? ""))
        }
        if let rateLimit, rateLimit.limit > 0,
           Double(rateLimit.remaining) < Double(rateLimit.limit) * rateLimitWarning {
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
        var waiting: [LinearIssue.Identifier] = []
        /// The workspace's CI runs the GitHub Actions spending limit stopped.
        var spendingLimit: SpendingLimitStop?

        init(claude: ClaudePause? = nil, waiting: [LinearIssue.Identifier] = [], spendingLimit: SpendingLimitStop? = nil) {
            self.claude = claude
            self.waiting = waiting
            self.spendingLimit = spendingLimit
        }

        /// The pauses in the state file for `workspace`.
        init(state: State, workspace: String, now: Date = Date()) {
            claude = state.claudePause.flatMap { $0.isOver(now: now) ? nil : $0 }
            let queued = state.workspaces[workspace]?.inFlight.values.filter(\.isQueued) ?? []
            waiting = queued.map(\.identifier).sorted { $0.sortsBefore($1) }
            spendingLimit = state.workspaces[workspace]?.spendingLimit
        }

        func risks(now: Date = Date()) -> [String] {
            var risks: [String] = []
            if let claude {
                let held = waiting.isEmpty ? "holds back no session here" : "holds back \(StandupView.list(waiting))"
                risks.append("Claude usage limit: sessions paused until \(StatusTime.clock(claude.until, now: now)), "
                    + "next check \(StatusTime.clock(claude.nextCheckAt, now: now)); \(held)")
            }
            if let stop = spendingLimit {
                risks.append("GitHub Actions spending limit: CI not started since \(StatusTime.clock(stop.since, now: now)) "
                    + "on \(stop.branches.sorted().joined(separator: ", ")); one stopped run is rerun each hour")
            }
            return risks
        }
    }

    /// The line `superlinear status` prints about standups.
    static func statusLine(state: State, standups: StandupRecord, workspaces: [String], now: Date = Date()) -> String {
        let last = workspaces.compactMap { standups[$0].lastStandupAt }.max()
        let pending = workspaces.reduce(0) { $0 + state.proposals(workspace: $1).filter { $0.status == .pending }.count }
        let needsHuman = workspaces.reduce(0) { $0 + (state.workspaces[$1]?.needsHuman.count ?? 0) }
        let when = last.map { "last \(StatusTime.rendered($0, now: now))" } ?? "none yet"
        return "Standup: \(when) · \(pending) pending proposal\(pending == 1 ? "" : "s") · "
            + "\(needsHuman) need\(needsHuman == 1 ? "s" : "") a human"
    }
}

extension StandupView {
    /// The view of the workspace's state, without what needs GitHub or Linear.
    init(
        workspace: String, state: WorkspaceState, standup: WorkspaceStandup,
        upcoming: [LinearIssue] = [], now: Date = Date()
    ) {
        self.workspace = workspace
        self.now = now
        since = Standup.since(standup, now: now)
        done = Standup.done(state, since: since, now: now)
        proposals = state.proposals.filter { $0.status == .pending }.sorted { $0.createdAt < $1.createdAt }
        needsHuman = Standup.needsHuman(state)
        let plan = Standup.plan(state, upcoming: upcoming, standup: standup)
        self.plan = plan.queue
        held = plan.held
        unblocked = standup.unblocked
    }

    func rendered(sections: [StandupSection] = StandupSection.allCases) -> String {
        var lines = ["\(workspace) · since \(StatusTime.rendered(since, now: now))"]
        lines += warnings.map { "  warning: \($0)" }
        for section in sections {
            lines.append("")
            lines += rendered(section: section)
        }
        return lines.joined(separator: "\n")
    }

    func rendered(section: StandupSection) -> [String] {
        let title = section.title
        switch section {
        case .done:
            return [title] + (done.isEmpty ? ["   Nothing"] : done.map { "   " + $0 })
        case .waitingOnYou:
            guard let waitingOnYou else { return [title, "   Not checked"] }
            return [title] + (waitingOnYou.isEmpty ? ["   Nothing"] : waitingOnYou.flatMap(Self.describe))
        case .proposals:
            return [title] + (proposals.isEmpty ? ["   None pending"] : proposals.flatMap { ProposalsCommand.describe($0, now: now) })
        case .needsHuman:
            return [title] + (needsHuman.isEmpty ? ["   Nothing"] : needsHuman.map(Self.describe))
        case .plan:
            var lines = [title]
            lines += plan.isEmpty ? ["   Nothing queued"] : Self.numbered(plan)
            if !held.isEmpty { lines += ["   Held"] + held.map { "     \(Self.line($0))" } }
            if !unblocked.isEmpty { lines.append("   Unblocked at the last standup: \(Self.list(unblocked))") }
            return lines
        case .risks:
            guard let risks else { return [title, "   Not checked"] }
            return [title] + (risks.isEmpty ? ["   None found"] : risks.map { "   " + $0 })
        }
    }

    static func list(_ identifiers: [LinearIssue.Identifier]) -> String {
        identifiers.map(\.rawValue).joined(separator: ", ")
    }

    static func describe(_ waiting: WaitingPullRequest) -> [String] {
        let pullRequest = waiting.pullRequest
        let indent = waiting.stackedOn == nil ? "   " : "     "
        let checks = waiting.ciNotStarted ? ReviewablePullRequest.CheckState.notStarted : pullRequest.checkState
        var notes = [pullRequest.reviewState.rawValue, checks.rawValue]
        if let below = waiting.stackedOn { notes.insert("stacked on #\(below)", at: 0) }
        let blocks = waiting.blockedIssues.count
        if blocks > 0 { notes.append("blocks \(blocks) issue\(blocks == 1 ? "" : "s")") }
        return [
            "\(indent)#\(pullRequest.number) \(pullRequest.title)",
            "\(indent)  " + (notes + [pullRequest.url]).joined(separator: " · "),
        ]
    }

    static func describe(_ item: NeedsHumanItem) -> String {
        let blocks = item.blockedIssues.isEmpty ? "" : " · blocks \(item.blockedIssues.count)"
        return "   \(item.issue.identifier)  \(item.issue.title)  [\(item.issue.labels.joined(separator: ", "))\(blocks)]"
    }

    static func line(_ item: PlanItem) -> String {
        ([item.identifier.rawValue, item.title].filter { !$0.isEmpty } + (item.queued ? ["(queued)"] : [])).joined(separator: "  ")
    }

    static func numbered(_ items: [PlanItem], prefix: String = "") -> [String] {
        items.enumerated().map { "   \(prefix)\($0.offset + 1). \(line($0.element))" }
    }
}

enum StandupError: Error, CustomStringConvertible, Equatable {
    case badPayload(String)
    case noItem(String)

    var description: String {
        switch self {
        case .badPayload(let message): "The edited change could not be read: \(message)"
        case .noItem(let text): "No item \(text)"
        }
    }
}

/// What the owner decided during a standup, before any of it is applied.
/// Each key action is one method here.
struct StandupSession: Sendable {
    let view: StandupView
    /// Proposals approved, with any edit, to apply at the end.
    var approved: [Proposal] = []
    /// Proposals rejected, as they are to be stored.
    var rejected: [Proposal] = []
    var deferred: [Proposal.ID] = []
    /// Issues to move to Done.
    var done: [NeedsHumanItem] = []
    var decisions: [Decision] = []
    /// Identifiers of held issues, by issue ID.
    var held: [LinearIssue.ID: LinearIssue.Identifier]
    /// The plan in its current order.
    var plan: [PlanItem]
    /// Whether the owner moved anything, so the order is worth keeping.
    var reordered = false
    var promoted: [PlanItem] = []

    /// A decision entered for an issue that needs a human.
    struct Decision: Sendable, Equatable {
        var item: NeedsHumanItem
        var text: String
    }

    init(view: StandupView, standup: WorkspaceStandup) {
        self.view = view
        held = standup.held
        // Held issues stay in the list, so they can be released.
        plan = view.plan + view.held
    }

    mutating func approve(_ proposal: Proposal) {
        forget(proposal.id)
        approved.append(proposal)
    }

    mutating func reject(_ proposal: Proposal, reason: String?, now: Date = Date()) {
        forget(proposal.id)
        var rejection = proposal
        rejection.status = .rejected
        let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        rejection.rejectionReason = reason?.isEmpty == false ? reason : nil
        rejection.decidedAt = now
        rejected.append(rejection)
    }

    mutating func `defer`(_ proposal: Proposal) {
        forget(proposal.id)
        deferred.append(proposal.id)
    }

    private mutating func forget(_ id: Proposal.ID) {
        approved.removeAll { $0.id == id }
        rejected.removeAll { $0.id == id }
        deferred.removeAll { $0 == id }
    }

    /// The payload as the owner edits it.
    static func editable(_ payload: ProposalPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }

    /// `proposal` with the payload read from `text`, the owner's edit. The
    /// kind cannot change.
    static func edited(_ proposal: Proposal, text: String) throws -> Proposal {
        let payload: ProposalPayload
        do {
            payload = try JSONDecoder().decode(ProposalPayload.self, from: Data(text.utf8))
        } catch {
            throw StandupError.badPayload("\(error)")
        }
        guard payload.kind == proposal.kind else {
            throw StandupError.badPayload("its kind changed from \(proposal.kind.rawValue) to \(payload.kind.rawValue)")
        }
        var proposal = proposal
        proposal.payload = payload
        return proposal
    }

    mutating func markDone(_ item: NeedsHumanItem) {
        guard !done.contains(item) else { return }
        done.append(item)
    }

    mutating func addDecision(_ item: NeedsHumanItem, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        decisions.append(Decision(item: item, text: text))
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Holds the plan's item at `index`, or releases it when held.
    mutating func toggleHold(_ index: Int) throws {
        let item = try planItem(index)
        if held[item.issueId] != nil {
            held[item.issueId] = nil
        } else {
            held[item.issueId] = item.identifier
        }
    }

    mutating func moveUp(_ index: Int) throws {
        _ = try planItem(index)
        guard index > 0 else { return }
        plan.swapAt(index, index - 1)
        reordered = true
    }

    mutating func moveDown(_ index: Int) throws {
        _ = try planItem(index)
        guard index < plan.count - 1 else { return }
        plan.swapAt(index, index + 1)
        reordered = true
    }

    /// Promotes the backlog's item at `index` to Todo, or takes the promotion back.
    mutating func togglePromotion(_ index: Int) throws {
        guard view.backlog.indices.contains(index) else { throw StandupError.noItem("b\(index + 1)") }
        let item = view.backlog[index]
        if let at = promoted.firstIndex(of: item) {
            promoted.remove(at: at)
        } else {
            promoted.append(item)
        }
    }

    private func planItem(_ index: Int) throws -> PlanItem {
        guard plan.indices.contains(index) else { throw StandupError.noItem("\(index + 1)") }
        return plan[index]
    }

    /// The plan as the owner left it, with holds marked.
    func renderedPlan() -> [String] {
        var lines = plan.enumerated().map { index, item in
            "   \(index + 1). \(StandupView.line(item))" + (held[item.issueId] != nil ? "  [held]" : "")
        }
        if lines.isEmpty { lines = ["   Nothing queued"] }
        if !view.backlog.isEmpty {
            lines.append("   Backlog")
            lines += view.backlog.enumerated().map { index, item in
                "   b\(index + 1). \(StandupView.line(item))" + (promoted.contains(item) ? "  [promote]" : "")
            }
        }
        return lines
    }
}
