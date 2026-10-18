import Foundation

/// An agent the daemon started and has not yet seen finish. Kept in the state
/// file so a restarted daemon can find it again: still running, finished while
/// the daemon was down, or interrupted and in need of resuming.
struct AgentRun: Codable, Sendable, Equatable {
    var issueId: String
    var identifier: LinearIssue.Identifier
    var branchName: String
    /// The Claude session the agent runs in, chosen by the daemon so it can be
    /// resumed by ID. Lowercase, as Claude names its transcripts.
    var sessionId: String
    /// The wrapper process running the agent, once launched.
    var pid: Int32?
    /// The kernel's start time for `pid`, so a reused pid is not mistaken for
    /// the agent.
    var processStartedAt: Date?
    /// How many times the run has been resumed after an interruption.
    var resumes: Int = 0
    /// When the issue joined the queue. Waiting runs start oldest first, and an
    /// interrupted run keeps its time, so it goes ahead of newer issues.
    var queuedAt: Date?
    /// Launches that failed, as when the disk is full. Absent in state files
    /// written before failures were counted.
    var launchFailures: Int?
    /// When the run first launched. Unlike `processStartedAt`, a resume does
    /// not move it. Absent in state files written before reviews were followed.
    var launchedAt: Date?
    /// The pull request whose review the run answers, for a run started by a
    /// review rather than by a new issue.
    var review: ReviewRequest?
    /// The pull request whose conflicts with its base branch the run
    /// resolves, for a run started by such a conflict.
    var conflict: ConflictRequest?
    /// The number of the GitHub issue the agent works on, when the run comes
    /// from GitHub rather than Linear.
    var gitHubIssue: Int? = nil
    /// Set when the run's session stopped at the Claude usage limit, until it
    /// launches again. Such a run waits out the pause, then goes first.
    var usageLimited: Bool?
    /// The pull request the issue's work is stacked on, for an issue started
    /// on top of its blocker's open pull request.
    var stack: StackBase?
    /// The issue's comments in Linear, for its prompt, and for a run started
    /// by the owner's comments, those to act on.
    var comments: CommentContext?

    /// Whether the owner's comments in Linear started the run.
    var answersComments: Bool { !(comments?.new.isEmpty ?? true) }

    /// Waiting for a free slot: recorded, but not launched, or launched and
    /// since requeued after an interruption.
    var isQueued: Bool { pid == nil }

    /// The run put back in the queue after its session stopped at the Claude
    /// usage limit. It is interrupted, not failed: it keeps its session ID,
    /// its place in the queue, and its counts of resumes and failed launches.
    func stoppedByUsageLimit() -> AgentRun {
        var run = self
        run.pid = nil
        run.processStartedAt = nil
        run.usageLimited = true
        return run
    }
}

/// A pull request with reviews for an agent to address.
struct ReviewRequest: Codable, Sendable, Equatable {
    var number: PullRequest.Number
    var url: String
    /// The reviews and comments that queued the run. Absent in state files
    /// written before comments were followed.
    var feedback: [PullRequestFeedback]? = nil
}

/// A pull request that conflicts with its base branch, for an agent to merge
/// the base branch into.
struct ConflictRequest: Codable, Sendable, Equatable {
    var number: PullRequest.Number
    var url: String
    var baseBranch: String
    /// The branch and base heads the conflict was found on.
    var attempt: ConflictAttempt
    /// The issue's review baseline from before the run, which the watch
    /// after it keeps: the run answers no reviews.
    var reviewsHandledThrough: Date?
}

/// The heads of a pull request's branch and of its base branch on the remote
/// when an agent was set to resolve their conflicts. Should they conflict
/// still with the same heads after it ends, the agent could not resolve them,
/// and another agent waits until one of the two moves.
struct ConflictAttempt: Codable, Sendable, Equatable {
    var head: String
    var base: String
}

/// An issue no agent starts on yet: one with open blockers, or one with a
/// human label. Each poll checks it again.
struct WaitingIssue: Codable, Sendable, Equatable {
    var identifier: LinearIssue.Identifier
    var title: String
    /// The identifiers of the open issues blocking it.
    var blockers: [LinearIssue.Identifier] = []
    /// Its human labels.
    var labels: [String] = []

    init(identifier: LinearIssue.Identifier, title: String, blockers: [LinearIssue.Identifier] = [], labels: [String] = []) {
        self.identifier = identifier
        self.title = title
        self.blockers = blockers
        self.labels = labels
    }

    init(_ issue: LinearIssue, blockers: [LinearIssue.Identifier] = [], labels: [String] = []) {
        self.init(identifier: issue.identifier, title: issue.title, blockers: blockers, labels: labels)
    }
}

struct WorkspaceState: Codable, Sendable {
    var processedIssueIds: Set<String>
    var lastPollTimestamp: Date
    /// Runs in flight, keyed by issue ID.
    var inFlight: [String: AgentRun]
    /// Issues whose agents have ended, awaiting their pull requests' merge,
    /// keyed by issue ID.
    var pendingMerges: [String: PendingMerge]
    /// Pull request URLs already linked to each issue in Linear, keyed by
    /// issue ID, so each is linked once.
    var linkedPullRequests: [String: [String]]
    /// The last poll, and when the next is due. Absent in state files written
    /// before polls were recorded, and until the first poll ends.
    var poll: PollRecord?
    /// Issues waiting on open blockers, keyed by issue ID.
    var blocked: [LinearIssue.ID: WaitingIssue]
    /// Issues with a human label, keyed by issue ID.
    var needsHuman: [LinearIssue.ID: WaitingIssue]
    /// When the daemon first polled the repository's GitHub issues. Issues you
    /// opened before then are left alone unless you comment `/superlinear-do`.
    var gitHubIssuesSince: Date?
    /// Proposed changes to Linear, pending and decided, oldest first.
    var proposals: [Proposal]
    /// What the daemon did on its own, oldest first, for `superlinear status`.
    var activity: [ActivityEvent]
    /// The repository's CI runs the GitHub Actions spending limit stopped,
    /// while there are any.
    var spendingLimit: SpendingLimitStop?
    /// The planning job the daemon is running, if any.
    var planningRun: PlanningRun?
    /// The planning jobs the daemon ran, oldest first.
    var planningRuns: [PlanningRunRecord]
    /// What superlinear handled of the owner's comments, by issue ID, or by
    /// `CommentLedger.Key.document` for the spec document.
    var commentLedgers: [CommentLedger.Key: CommentLedger]
    /// Issues whose last agent ended without a pull request, by issue ID.
    var endedAgents: [LinearIssue.ID: EndedAgent]
    /// The sessions that answered the owner's comments, oldest first.
    var commentAnswers: [CommentAnswerRecord]

    init() {
        processedIssueIds = []
        lastPollTimestamp = .distantPast
        inFlight = [:]
        pendingMerges = [:]
        linkedPullRequests = [:]
        blocked = [:]
        needsHuman = [:]
        proposals = []
        activity = []
        planningRuns = []
        commentLedgers = [:]
        endedAgents = [:]
        commentAnswers = []
    }

    // State files written before runs were tracked have no `inFlight`, those
    // written before pull requests were watched have no `pendingMerges` or
    // `linkedPullRequests`, and those written before blockers and human labels
    // were followed have no `blocked` or `needsHuman`. Those from before
    // proposals have none, those from before activity was kept none, and
    // those from before the planning job no planning runs. Those from before
    // comments were answered have no ledgers, ended agents or answers.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        processedIssueIds = try container.decode(Set<String>.self, forKey: .processedIssueIds)
        lastPollTimestamp = try container.decode(Date.self, forKey: .lastPollTimestamp)
        inFlight = try container.decodeIfPresent([String: AgentRun].self, forKey: .inFlight) ?? [:]
        pendingMerges = try container.decodeIfPresent([String: PendingMerge].self, forKey: .pendingMerges) ?? [:]
        linkedPullRequests = try container.decodeIfPresent([String: [String]].self, forKey: .linkedPullRequests) ?? [:]
        poll = try container.decodeIfPresent(PollRecord.self, forKey: .poll)
        blocked = try container.decodeIfPresent([LinearIssue.ID: WaitingIssue].self, forKey: .blocked) ?? [:]
        needsHuman = try container.decodeIfPresent([LinearIssue.ID: WaitingIssue].self, forKey: .needsHuman) ?? [:]
        gitHubIssuesSince = try container.decodeIfPresent(Date.self, forKey: .gitHubIssuesSince)
        proposals = try container.decodeIfPresent([Proposal].self, forKey: .proposals) ?? []
        activity = try container.decodeIfPresent([ActivityEvent].self, forKey: .activity) ?? []
        spendingLimit = try container.decodeIfPresent(SpendingLimitStop.self, forKey: .spendingLimit)
        planningRun = try container.decodeIfPresent(PlanningRun.self, forKey: .planningRun)
        planningRuns = try container.decodeIfPresent([PlanningRunRecord].self, forKey: .planningRuns) ?? []
        commentLedgers = try container.decodeIfPresent([CommentLedger.Key: CommentLedger].self, forKey: .commentLedgers) ?? [:]
        endedAgents = try container.decodeIfPresent([LinearIssue.ID: EndedAgent].self, forKey: .endedAgents) ?? [:]
        commentAnswers = try container.decodeIfPresent([CommentAnswerRecord].self, forKey: .commentAnswers) ?? []
    }

    /// Issues an agent may not start on yet.
    var waitingIssueIds: Set<LinearIssue.ID> { Set(blocked.keys).union(needsHuman.keys) }
}

/// When a workspace's last poll ended, how, and when the next is due.
struct PollRecord: Codable, Sendable, Equatable {
    var endedAt: Date
    var nextAt: Date
    /// Why the poll failed, if it did.
    var error: String?

    /// How long a poll runs before the status calls it slow.
    static let slowPoll: TimeInterval = 10 * 60

    /// The line `superlinear status` prints about it. Once the next poll is
    /// due, it is running.
    func rendered(daemonRunning: Bool, now: Date = Date()) -> String {
        var parts = ["last poll ended \(StatusTime.rendered(endedAt, now: now))"]
        if let error { parts[0] += ", failed: \(error)" }
        if !daemonRunning {
            parts.append("no next poll: the daemon is not running")
        } else if nextAt <= now {
            // The next poll started when due, and records itself when it ends.
            let since = "polling since \(StatusTime.rendered(nextAt, now: now))"
            parts.append(nextAt < now.addingTimeInterval(-Self.slowPoll) ? since + ", which is slow" : since)
        } else {
            parts.append("next poll \(StatusTime.rendered(nextAt, now: now))")
        }
        return parts.joined(separator: " · ")
    }
}

struct State: Codable, Sendable {
    var workspaces: [String: WorkspaceState]
    /// The pause of every Claude session while the usage limit is used up.
    /// All workspaces share one Claude login, so it is for all of them.
    var claudePause: ClaudePause?

    init() {
        workspaces = [:]
    }

    static func load(from url: URL = stateFileURL()) -> State {
        guard let data = try? Data(contentsOf: url) else { return State() }
        do {
            return try decoded(from: data)
        } catch {
            // Starting empty starts agents again on issues already handled in
            // `ready` mode, and forgets the waiting ones, so say so.
            print("[superlinear] Could not read \(url.path), starting with empty state: \(error)")
            return State()
        }
    }

    func save(to url: URL = stateFileURL()) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tmpURL = url.appendingPathExtension("tmp")
        try encoded().write(to: tmpURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
    }

    // Encoding and decoding must agree on dates. They once did not: dates were
    // written as ISO 8601 strings and read back as numbers, so every load failed
    // and each restart began from empty state.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func decoded(from data: Data) throws -> State {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(State.self, from: data)
    }

    /// Ends the Claude pause, as `superlinear resume` does. Returns false when
    /// there was none.
    @discardableResult
    mutating func liftClaudePause() -> Bool {
        defer { claudePause = nil }
        return claudePause != nil
    }

    /// The runs waiting for a slot in every workspace, which a Claude pause
    /// holds back.
    var queuedRuns: [AgentRun] {
        workspaces.values.flatMap { $0.inFlight.values.filter(\.isQueued) }
    }

    mutating func markProcessed(_ issueId: String, workspace: String) {
        workspaces[workspace, default: WorkspaceState()].processedIssueIds.insert(issueId)
    }

    mutating func recordPoll(_ poll: PollRecord, workspace: String) {
        workspaces[workspace, default: WorkspaceState()].poll = poll
    }

    mutating func updateLastPoll(_ date: Date, workspace: String) {
        workspaces[workspace, default: WorkspaceState()].lastPollTimestamp = date
    }

    func isProcessed(_ issueId: String, workspace: String) -> Bool {
        workspaces[workspace]?.processedIssueIds.contains(issueId) ?? false
    }

    /// When GitHub issues were first polled, set to `now` on the first call.
    mutating func gitHubIssuesSince(workspace: String, now: Date = Date()) -> Date {
        if let since = workspaces[workspace]?.gitHubIssuesSince { return since }
        workspaces[workspace, default: WorkspaceState()].gitHubIssuesSince = now
        return now
    }

    func lastPollTimestamp(workspace: String) -> Date {
        workspaces[workspace]?.lastPollTimestamp ?? .distantPast
    }

    /// The merge watch of the issue whose branch is `branch`, if any.
    func pendingMerge(branch: String, workspace: String) -> PendingMerge? {
        workspaces[workspace]?.pendingMerges.values.first { $0.branchName == branch }
    }

    /// The merge watches of the workspace's issues by identifier, for the
    /// blockers an issue might stack on.
    func pendingMergesByIdentifier(workspace: String) -> [LinearIssue.Identifier: PendingMerge] {
        Dictionary(pendingMerges(workspace: workspace).map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Records what the issue's pull request is stacked on now.
    mutating func updateStack(_ stack: StackBase?, issueId: String, workspace: String) {
        workspaces[workspace]?.pendingMerges[issueId]?.stack = stack
    }

    /// Replaces the workspace's waiting issues with those of the latest poll,
    /// which checked every one of them again.
    mutating func recordWaiting(
        blocked: [LinearIssue.ID: WaitingIssue], needsHuman: [LinearIssue.ID: WaitingIssue], workspace: String
    ) {
        workspaces[workspace, default: WorkspaceState()].blocked = blocked
        workspaces[workspace, default: WorkspaceState()].needsHuman = needsHuman
    }

    /// Issues the daemon has queued, run or watched, which no poll starts again.
    func handledIssueIds(workspace: String) -> Set<LinearIssue.ID> {
        guard let state = workspaces[workspace] else { return [] }
        let ids = state.processedIssueIds.union(state.inFlight.keys).union(state.pendingMerges.keys)
        return Set(ids.map(LinearIssue.ID.init(rawValue:)))
    }

    /// Records a run, replacing any earlier record for the same issue.
    mutating func recordRun(_ run: AgentRun, workspace: String) {
        workspaces[workspace, default: WorkspaceState()].inFlight[run.issueId] = run
    }

    mutating func removeRun(issueId: String, workspace: String) {
        workspaces[workspace]?.inFlight[issueId] = nil
    }

    func runs(workspace: String) -> [AgentRun] {
        workspaces[workspace].map { Array($0.inFlight.values) } ?? []
    }

    mutating func awaitMerge(_ pending: PendingMerge, workspace: String) {
        workspaces[workspace, default: WorkspaceState()].pendingMerges[pending.issueId] = pending
    }

    /// Hands an issue awaiting its merge to a run that addresses a review or
    /// resolves conflicts. The linked pull requests stay recorded, as the run
    /// goes on following them.
    mutating func startReview(_ run: AgentRun, workspace: String) {
        workspaces[workspace]?.pendingMerges[run.issueId] = nil
        recordRun(run, workspace: workspace)
    }

    mutating func stopAwaitingMerge(issueId: String, workspace: String) {
        workspaces[workspace]?.pendingMerges[issueId] = nil
        // Nothing checks this issue's pull requests any more.
        workspaces[workspace]?.linkedPullRequests[issueId] = nil
    }

    mutating func forgetLinkedPullRequests(issueId: String, workspace: String) {
        workspaces[workspace]?.linkedPullRequests[issueId] = nil
    }

    func linkedPullRequests(issueId: String, workspace: String) -> Set<String> {
        Set(workspaces[workspace]?.linkedPullRequests[issueId] ?? [])
    }

    mutating func recordLinkedPullRequest(_ url: String, issueId: String, workspace: String) {
        var urls = workspaces[workspace, default: WorkspaceState()].linkedPullRequests[issueId] ?? []
        guard !urls.contains(url) else { return }
        urls.append(url)
        workspaces[workspace, default: WorkspaceState()].linkedPullRequests[issueId] = urls
    }

    func pendingMerges(workspace: String) -> [PendingMerge] {
        workspaces[workspace].map { Array($0.pendingMerges.values) } ?? []
    }

    func proposals(workspace: String) -> [Proposal] {
        workspaces[workspace]?.proposals ?? []
    }

    /// Adds a proposal, or replaces the one with its ID.
    mutating func recordProposal(_ proposal: Proposal, workspace: String) {
        var proposals = workspaces[workspace, default: WorkspaceState()].proposals
        if let index = proposals.firstIndex(where: { $0.id == proposal.id }) {
            proposals[index] = proposal
        } else {
            proposals.append(proposal)
        }
        workspaces[workspace, default: WorkspaceState()].proposals = proposals
    }

    /// Rejects a pending proposal, so the same change is not proposed again.
    /// Returns false when no pending proposal has that ID.
    @discardableResult
    mutating func rejectProposal(id: Proposal.ID, reason: String?, workspace: String, now: Date = Date()) -> Bool {
        guard var proposal = proposals(workspace: workspace).first(where: { $0.id == id }),
              proposal.status == .pending
        else { return false }
        proposal.status = .rejected
        proposal.rejectionReason = reason
        proposal.decidedAt = now
        recordProposal(proposal, workspace: workspace)
        return true
    }

    /// How long applied and expired proposals stay listed. Rejected ones stay
    /// for good, as they keep the same change from being proposed again.
    static let decidedProposalRetention: TimeInterval = 30 * 24 * 60 * 60

    /// Expires pending proposals put in Linear more than `days` days ago, and
    /// drops applied and expired ones decided more than
    /// `decidedProposalRetention` ago. A proposal not yet in Linear never
    /// expires. Returns the proposals it expired.
    @discardableResult
    mutating func expireProposals(olderThanDays days: Int, workspace: String, now: Date = Date()) -> [Proposal] {
        guard var proposals = workspaces[workspace]?.proposals, !proposals.isEmpty else { return [] }
        let cutoff = now.addingTimeInterval(-TimeInterval(days) * 24 * 60 * 60)
        var expired: [Proposal] = []
        for index in proposals.indices where proposals[index].status == .pending {
            guard let posted = proposals[index].post?.postedAt, posted < cutoff else { continue }
            proposals[index].status = .expired
            proposals[index].decidedAt = now
            expired.append(proposals[index])
        }
        let forgetBefore = now.addingTimeInterval(-Self.decidedProposalRetention)
        proposals.removeAll { proposal in
            [.applied, .expired].contains(proposal.status) && (proposal.decidedAt ?? proposal.createdAt) < forgetBefore
        }
        workspaces[workspace]?.proposals = proposals
        return expired
    }

    /// Records something the daemon did on its own, and drops events older
    /// than `ActivityEvent.retention`.
    mutating func recordActivity(_ event: ActivityEvent, workspace: String) {
        var activity = workspaces[workspace, default: WorkspaceState()].activity
        activity.append(event)
        activity.removeAll { $0.time < event.time.addingTimeInterval(-ActivityEvent.retention) }
        workspaces[workspace, default: WorkspaceState()].activity = activity
    }

    /// The state file with the proposals of `superlinear plan` taken in, as
    /// the daemon takes them in at each poll, so a reader sees them at once.
    static func loadWithPlanning(from url: URL, planning: PlanningRecord) -> State {
        var state = load(from: url)
        for (name, record) in planning.workspaces {
            state.takeIn(record, workspace: name, now: Date())
        }
        return state
    }

    /// Adds the proposals `superlinear plan` stored that the workspace lacks.
    /// Those older than `WorkspacePlanning.retention` are left out: the state
    /// file may have dropped them since. Returns whether it added any.
    @discardableResult
    mutating func takeIn(_ planning: WorkspacePlanning, workspace: String, now: Date) -> Bool {
        let known = Set(proposals(workspace: workspace).map(\.id))
        let cutoff = now.addingTimeInterval(-WorkspacePlanning.retention)
        let new = planning.proposals.filter { !known.contains($0.id) && $0.createdAt >= cutoff }
        guard !new.isEmpty else { return false }
        workspaces[workspace, default: WorkspaceState()].proposals += new
        return true
    }

    /// The planning runs of the daemon and of `superlinear plan`, oldest first.
    func planningRuns(workspace: String, planning: WorkspacePlanning) -> [PlanningRunRecord] {
        ((workspaces[workspace]?.planningRuns ?? []) + planning.runs).sorted { $0.startedAt < $1.startedAt }
    }

    mutating func startPlanning(_ run: PlanningRun, workspace: String) {
        workspaces[workspace, default: WorkspaceState()].planningRun = run
    }

    mutating func finishPlanning(_ record: PlanningRunRecord, workspace: String) {
        workspaces[workspace, default: WorkspaceState()].planningRun = nil
        let runs = workspaces[workspace]?.planningRuns ?? []
        workspaces[workspace]?.planningRuns = PlanningHistory.appending(record, to: runs)
    }

    /// Adds the ledgers of issues watched for the first time, drops those of
    /// issues no longer watched, and forgets ended agents whose issues were
    /// completed or canceled. The spec document's ledger is kept.
    mutating func recordCommentWatch(_ plan: CommentTriage.Plan, workspace: String) {
        var ledgers = workspaces[workspace, default: WorkspaceState()].commentLedgers
        ledgers = ledgers.filter { plan.watched.contains($0.key) || $0.key.isDocument }
        ledgers.merge(plan.baselines) { current, _ in current }
        workspaces[workspace, default: WorkspaceState()].commentLedgers = ledgers
        for id in plan.finished { workspaces[workspace]?.endedAgents[id] = nil }
    }

    /// Records the comments as handled, each with the text it has now.
    mutating func handleComments(_ comments: [FreshComment], key: CommentLedger.Key, since: Date, workspace: String) {
        var ledger = workspaces[workspace, default: WorkspaceState()].commentLedgers[key] ?? CommentLedger(since: since)
        ledger.handle(comments)
        workspaces[workspace, default: WorkspaceState()].commentLedgers[key] = ledger
    }

    /// How many answer sessions are kept for their token use.
    static let commentAnswerRetention = 100

    mutating func recordCommentAnswer(_ record: CommentAnswerRecord, workspace: String) {
        var answers = workspaces[workspace, default: WorkspaceState()].commentAnswers
        answers.append(record)
        workspaces[workspace, default: WorkspaceState()].commentAnswers = Array(answers.suffix(Self.commentAnswerRetention))
    }

    static func stateFileURL() -> URL {
        URL(fileURLWithPath: "\(Paths.home)/.local/share/superlinear/state.json")
    }
}
