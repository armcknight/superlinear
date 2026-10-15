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

    init() {
        processedIssueIds = []
        lastPollTimestamp = .distantPast
        inFlight = [:]
        pendingMerges = [:]
        linkedPullRequests = [:]
    }

    // State files written before runs were tracked have no `inFlight`, and
    // those written before pull requests were watched have no `pendingMerges`
    // or `linkedPullRequests`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        processedIssueIds = try container.decode(Set<String>.self, forKey: .processedIssueIds)
        lastPollTimestamp = try container.decode(Date.self, forKey: .lastPollTimestamp)
        inFlight = try container.decodeIfPresent([String: AgentRun].self, forKey: .inFlight) ?? [:]
        pendingMerges = try container.decodeIfPresent([String: PendingMerge].self, forKey: .pendingMerges) ?? [:]
        linkedPullRequests = try container.decodeIfPresent([String: [String]].self, forKey: .linkedPullRequests) ?? [:]
        poll = try container.decodeIfPresent(PollRecord.self, forKey: .poll)
    }
}

/// When a workspace's last poll ended, how, and when the next is due.
struct PollRecord: Codable, Sendable, Equatable {
    var endedAt: Date
    var nextAt: Date
    /// Why the poll failed, if it did.
    var error: String?

    /// The line `superlinear status` prints about it. A poll that should have
    /// run while the daemon is up is overdue: polls are taking long.
    func rendered(daemonRunning: Bool, now: Date = Date()) -> String {
        var parts = ["last poll ended \(StatusTime.rendered(endedAt, now: now))"]
        if let error { parts[0] += ", failed: \(error)" }
        if !daemonRunning {
            parts.append("no next poll: the daemon is not running")
        } else if nextAt < now.addingTimeInterval(-60) {
            parts.append("next poll overdue since \(StatusTime.rendered(nextAt, now: now)); one is still running")
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
            // Starting empty reprocesses every backlog issue, so say so.
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

    static func stateFileURL() -> URL {
        URL(fileURLWithPath: "\(Paths.home)/.local/share/superlinear/state.json")
    }
}
