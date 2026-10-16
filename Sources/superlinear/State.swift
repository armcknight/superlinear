import Foundation

/// An agent the daemon started and has not yet seen finish. Kept in the state
/// file so a restarted daemon can find it again: still running, finished while
/// the daemon was down, or interrupted and in need of resuming.
struct AgentRun: Codable, Sendable, Equatable {
    var issueId: String
    var identifier: String
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

    /// Waiting for a free slot: recorded, but not launched, or launched and
    /// since requeued after an interruption.
    var isQueued: Bool { pid == nil }
}

/// A pull request with reviews for an agent to address.
struct ReviewRequest: Codable, Sendable, Equatable {
    var number: Int
    var url: String
}

/// A pull request that conflicts with its base branch, for an agent to merge
/// the base branch into.
struct ConflictRequest: Codable, Sendable, Equatable {
    var number: Int
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
    var identifier: String
    var title: String
    /// The identifiers of the open issues blocking it.
    var blockers: [String] = []
    /// Its human labels.
    var labels: [String] = []

    init(identifier: String, title: String, blockers: [String] = [], labels: [String] = []) {
        self.identifier = identifier
        self.title = title
        self.blockers = blockers
        self.labels = labels
    }

    init(_ issue: LinearIssue, blockers: [String] = [], labels: [String] = []) {
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
    /// Proposed changes to Linear, pending and decided, oldest first.
    var proposals: [Proposal]

    init() {
        processedIssueIds = []
        lastPollTimestamp = .distantPast
        inFlight = [:]
        pendingMerges = [:]
        linkedPullRequests = [:]
        blocked = [:]
        needsHuman = [:]
        proposals = []
    }

    // State files written before runs were tracked have no `inFlight`, those
    // written before pull requests were watched have no `pendingMerges` or
    // `linkedPullRequests`, and those written before blockers and human labels
    // were followed have no `blocked` or `needsHuman`. Those from before
    // proposals have none.
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
        proposals = try container.decodeIfPresent([Proposal].self, forKey: .proposals) ?? []
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

    func lastPollTimestamp(workspace: String) -> Date {
        workspaces[workspace]?.lastPollTimestamp ?? .distantPast
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

    /// Expires pending proposals older than `days` days, and drops applied and
    /// expired ones decided more than `decidedProposalRetention` ago. Returns
    /// the proposals it expired.
    @discardableResult
    mutating func expireProposals(olderThanDays days: Int, workspace: String, now: Date = Date()) -> [Proposal] {
        guard var proposals = workspaces[workspace]?.proposals, !proposals.isEmpty else { return [] }
        let cutoff = now.addingTimeInterval(-TimeInterval(days) * 24 * 60 * 60)
        var expired: [Proposal] = []
        for index in proposals.indices where proposals[index].status == .pending && proposals[index].createdAt < cutoff {
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

    static func stateFileURL() -> URL {
        URL(fileURLWithPath: "\(Paths.home)/.local/share/superlinear/state.json")
    }
}
