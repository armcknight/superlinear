import Foundation

/// An issue that needs a human, with the number of open issues waiting on
/// it, directly and through others.
struct NeedsHumanItem: Sendable, Equatable {
    var id: LinearIssue.ID
    var issue: WaitingIssue
    var blocking: Int
}

/// An issue in the plan for today: queued for an agent, about to be, held,
/// or in the backlog.
struct PlanItem: Sendable, Equatable {
    var issueId: String
    var identifier: String
    var title: String
    /// The daemon has queued it already.
    var queued = false
}

/// An open pull request waiting on the owner, with what it holds back.
struct WaitingPullRequest: Sendable, Equatable {
    var pullRequest: ReviewablePullRequest
    /// The pull request it is stacked on, if any.
    var stackedOn: Int?
    /// The open issues its issues block, directly and indirectly.
    var blocking: Int
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
    var unblocked: [String] = []
    /// Backlog issues that could be promoted to Todo.
    var backlog: [PlanItem] = []
    /// Section 6, or nil when it was not gathered.
    var risks: [String]?
    /// Problems that left the view incomplete.
    var warnings: [String] = []

    /// The sections `--print` shows.
    static let printedSections = [1, 3, 4, 5]
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
        var lines: [(Date, String)] = state.activity.filter { $0.time >= since }.map { ($0.time, $0.rendered) }
        for proposal in state.proposals where proposal.trust == .auto && proposal.status == .applied {
            guard let decided = proposal.decidedAt, decided >= since else { continue }
            lines.append((decided, "applied automatically: \(proposal.kind.rawValue) → \(targetName(proposal.target))"))
        }
        return lines.sorted { $0.0 < $1.0 }.map { "\(StatusTime.rendered($0.0, now: now))  \($0.1)" }
    }

    static func targetName(_ target: ProposalTarget) -> String {
        "\(target.kind.rawValue) \(target.name ?? target.rawID)"
    }

    /// The number of open issues each issue blocks, directly and through the
    /// issues it blocks, by identifier, from the daemon's blocked issues.
    static func blocking(_ blocked: [LinearIssue.ID: WaitingIssue]) -> [String: Int] {
        var blockedBy: [String: Set<String>] = [:]
        for issue in blocked.values {
            for blocker in issue.blockers { blockedBy[blocker, default: []].insert(issue.identifier) }
        }
        var counts: [String: Int] = [:]
        for start in blockedBy.keys {
            var seen: Set<String> = []
            var next = Array(blockedBy[start] ?? [])
            while let identifier = next.popLast() {
                guard identifier != start, seen.insert(identifier).inserted else { continue }
                next += blockedBy[identifier] ?? []
            }
            counts[start] = seen.count
        }
        return counts
    }

    /// Section 4: the issues that need a human, those blocking the most first.
    static func needsHuman(_ state: WorkspaceState) -> [NeedsHumanItem] {
        let counts = blocking(state.blocked)
        return state.needsHuman.map { id, issue in
            NeedsHumanItem(id: id, issue: issue, blocking: counts[issue.identifier] ?? 0)
        }.sorted { a, b in
            a.blocking == b.blocking
                ? a.issue.identifier.localizedStandardCompare(b.issue.identifier) == .orderedAscending
                : a.blocking > b.blocking
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
        let counts = blocking(state.blocked)
        let byHead = Dictionary(ready.map { ($0.headRefName, $0) }, uniquingKeysWith: { a, _ in a })
        func parent(_ pullRequest: ReviewablePullRequest) -> ReviewablePullRequest? {
            pullRequest.baseRefName.flatMap { byHead[$0] }.flatMap { $0.number == pullRequest.number ? nil : $0 }
        }
        var children: [Int: [ReviewablePullRequest]] = [:]
        for pullRequest in ready {
            if let parent = parent(pullRequest) { children[parent.number, default: []].append(pullRequest) }
        }
        func blocks(_ pullRequest: ReviewablePullRequest) -> Int {
            pullRequest.issueIdentifiers.reduce(0) { $0 + (counts[$1] ?? 0) }
        }

        var stacks: [(weight: Int, root: Int, items: [WaitingPullRequest])] = []
        var placed: Set<Int> = []
        for root in ready.sorted(by: { $0.number < $1.number }) where parent(root) == nil {
            var items: [WaitingPullRequest] = []
            var next = [(root, Int?.none)]
            while !next.isEmpty {
                let (pullRequest, below) = next.removeFirst()
                guard placed.insert(pullRequest.number).inserted else { continue }
                items.append(WaitingPullRequest(pullRequest: pullRequest, stackedOn: below, blocking: blocks(pullRequest)))
                let above = (children[pullRequest.number] ?? []).sorted { $0.number < $1.number }
                next = above.map { ($0, pullRequest.number) } + next
            }
            let weight = items.reduce(0) { $0 + $1.blocking } + items.count - 1
            stacks.append((weight, root.number, items))
        }
        // Pull requests in a cycle of bases have no bottom; list them alone.
        for pullRequest in ready where !placed.contains(pullRequest.number) {
            stacks.append((blocks(pullRequest), pullRequest.number,
                           [WaitingPullRequest(pullRequest: pullRequest, stackedOn: nil, blocking: blocks(pullRequest))]))
        }
        return stacks.sorted { $0.weight == $1.weight ? $0.root < $1.root : $0.weight > $1.weight }.flatMap(\.items)
    }

    /// Section 5: the issues agents start next, in the order the daemon will
    /// start them, and those held. `upcoming` are the ready issues not yet
    /// queued, in the selection's order.
    static func plan(
        _ state: WorkspaceState, upcoming: [LinearIssue], standup: WorkspaceStandup
    ) -> (plan: [PlanItem], held: [PlanItem]) {
        let queued = state.inFlight.values.filter(\.isFresh)
            .sorted { a, b in
                let (dateA, dateB) = (a.queuedAt ?? .distantPast, b.queuedAt ?? .distantPast)
                return dateA == dateB ? a.identifier < b.identifier : dateA < dateB
            }
            .map { PlanItem(issueId: $0.issueId, identifier: $0.identifier, title: "", queued: true) }
        let queuedIds = Set(queued.map(\.issueId))
        let next = upcoming.filter { !queuedIds.contains($0.id.rawValue) }
            .map { PlanItem(issueId: $0.id.rawValue, identifier: $0.identifier, title: $0.title) }
        let all = standup.ordered(queued + next, id: \.issueId)
        var held = all.filter { standup.held[$0.issueId] != nil }
        let listed = Set(held.map(\.issueId))
        // Held issues the daemon has not queued, and no ready list showed.
        for (id, identifier) in standup.held.sorted(by: { $0.value < $1.value }) where !listed.contains(id) {
            held.append(PlanItem(issueId: id, identifier: identifier, title: ""))
        }
        return (all.filter { standup.held[$0.issueId] == nil }, held)
    }

    /// The issues in `blocked` whose every open blocker is in `closed`.
    static func unblocked(_ blocked: [LinearIssue.ID: WaitingIssue], closing closed: Set<String>) -> [String] {
        blocked.values.filter { !$0.blockers.isEmpty && Set($0.blockers).isSubset(of: closed) }
            .map(\.identifier)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The most recent workflow run on the default branch, and GitHub's rate
    /// limit, as risks.
    struct DefaultBranchRun: Decodable, Sendable, Equatable {
        var status: String
        var conclusion: String?
        var url: String?
        var workflowName: String?
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
        defaultBranch: String?, latestRun: DefaultBranchRun?, rateLimit: RateLimit?, now: Date = Date()
    ) -> [String] {
        var risks: [String] = []
        if let defaultBranch, let run = latestRun, run.status == "completed",
           let conclusion = run.conclusion, !["success", "skipped", "neutral"].contains(conclusion) {
            let name = run.workflowName.map { " (\($0))" } ?? ""
            risks.append("CI \(conclusion) on \(defaultBranch)\(name)" + (run.url.map { ": \($0)" } ?? ""))
        }
        if let rateLimit, rateLimit.limit > 0,
           Double(rateLimit.remaining) < Double(rateLimit.limit) * rateLimitWarning {
            risks.append("GitHub rate limit: \(rateLimit.remaining) of \(rateLimit.limit) left, "
                + "resets \(StatusTime.rendered(rateLimit.reset, now: now))")
        }
        // TODO: SPL-26 adds budgets, and SPL-13 milestone forecasts; list
        // budgets used and milestones forecast to be late here.
        return risks
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
        (plan, held) = Standup.plan(state, upcoming: upcoming, standup: standup)
        unblocked = standup.unblocked
    }

    func rendered(sections: [Int] = Array(1...6)) -> String {
        var lines = ["\(workspace) · since \(StatusTime.rendered(since, now: now))"]
        lines += warnings.map { "  warning: \($0)" }
        for section in sections {
            lines.append("")
            lines += rendered(section: section)
        }
        return lines.joined(separator: "\n")
    }

    func rendered(section: Int) -> [String] {
        switch section {
        case 1:
            return ["1. Done autonomously"] + (done.isEmpty ? ["   Nothing"] : done.map { "   " + $0 })
        case 2:
            guard let waitingOnYou else { return ["2. Waiting on you", "   Not checked"] }
            return ["2. Waiting on you"] + (waitingOnYou.isEmpty ? ["   Nothing"] : waitingOnYou.flatMap(Self.describe))
        case 3:
            return ["3. Proposals"] + (proposals.isEmpty ? ["   None pending"] : proposals.flatMap { ProposalsCommand.describe($0, now: now) })
        case 4:
            return ["4. Needs human"] + (needsHuman.isEmpty ? ["   Nothing"] : needsHuman.map(Self.describe))
        case 5:
            var lines = ["5. Plan for today"]
            lines += plan.isEmpty ? ["   Nothing queued"] : Self.numbered(plan)
            if !held.isEmpty { lines += ["   Held"] + held.map { "     \(Self.line($0))" } }
            if !unblocked.isEmpty { lines.append("   Unblocked at the last standup: \(unblocked.joined(separator: ", "))") }
            return lines
        case 6:
            guard let risks else { return ["6. Risks", "   Not checked"] }
            return ["6. Risks"] + (risks.isEmpty ? ["   None found"] : risks.map { "   " + $0 })
        default:
            return []
        }
    }

    static func describe(_ waiting: WaitingPullRequest) -> [String] {
        let pullRequest = waiting.pullRequest
        let indent = waiting.stackedOn == nil ? "   " : "     "
        var notes = [pullRequest.reviewState.rawValue, pullRequest.checkState.rawValue]
        if let below = waiting.stackedOn { notes.insert("stacked on #\(below)", at: 0) }
        if waiting.blocking > 0 { notes.append("blocks \(waiting.blocking) issue\(waiting.blocking == 1 ? "" : "s")") }
        return [
            "\(indent)#\(pullRequest.number) \(pullRequest.title)",
            "\(indent)  " + (notes + [pullRequest.url]).joined(separator: " · "),
        ]
    }

    static func describe(_ item: NeedsHumanItem) -> String {
        let blocks = item.blocking > 0 ? " · blocks \(item.blocking)" : ""
        return "   \(item.issue.identifier)  \(item.issue.title)  [\(item.issue.labels.joined(separator: ", "))\(blocks)]"
    }

    static func line(_ item: PlanItem) -> String {
        ([item.identifier, item.title].filter { !$0.isEmpty } + (item.queued ? ["(queued)"] : [])).joined(separator: "  ")
    }

    static func numbered(_ items: [PlanItem], prefix: String = "") -> [String] {
        items.enumerated().map { "   \(prefix)\($0.offset + 1). \(line($0.element))" }
    }
}

enum StandupError: Error, CustomStringConvertible, Equatable {
    case badDate(String)
    case badPayload(String)
    case noItem(String)

    var description: String {
        switch self {
        case .badDate(let text): "\"\(text)\" is not a date like 2026-10-31"
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
    var decisions: [(item: NeedsHumanItem, text: String)] = []
    var dueDates: [(item: NeedsHumanItem, date: String)] = []
    /// Identifiers of held issues, by issue ID.
    var held: [String: String]
    /// The plan in its current order.
    var plan: [PlanItem]
    /// Whether the owner moved anything, so the order is worth keeping.
    var reordered = false
    var promoted: [PlanItem] = []

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
        decisions.append((item, text))
    }

    mutating func setDueDate(_ item: NeedsHumanItem, date: String) throws {
        let date = date.trimmingCharacters(in: .whitespaces)
        guard date.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil, Self.dayFormatter.date(from: date) != nil else {
            throw StandupError.badDate(date)
        }
        dueDates.removeAll { $0.item == item }
        dueDates.append((item, date))
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
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
