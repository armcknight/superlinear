import Foundation
import Tagged

/// A comment in Linear, on an issue or a document, as superlinear reads it to
/// find the owner's.
struct LinearThreadComment: Codable, Sendable, Equatable {
    var id: LinearComment.ID
    var body: String
    var userId: LinearUser.ID?
    /// The author's name, for the prompts.
    var author: String?
    var createdAt: Date
    /// When its text was last edited, if it was.
    var editedAt: Date?
    /// The comment it replies to. Linear's threads are one level deep, so
    /// this is the thread's first comment.
    var parentId: LinearComment.ID?
    var url: String?

    init(
        id: LinearComment.ID, body: String, userId: LinearUser.ID?, author: String? = nil, createdAt: Date,
        editedAt: Date? = nil, parentId: LinearComment.ID? = nil, url: String? = nil
    ) {
        self.id = id
        self.body = body
        self.userId = userId
        self.author = author
        self.createdAt = createdAt
        self.editedAt = editedAt
        self.parentId = parentId
        self.url = url
    }

    /// The first comment of its thread, which a reply goes under.
    var rootId: LinearComment.ID { parentId ?? id }
}

/// An issue with its comments, oldest first, as a poll reads them, and
/// what a session that answers a comment on it is told of it.
struct IssueComments: Sendable, Equatable {
    var id: LinearIssue.ID
    var identifier: LinearIssue.Identifier
    var stateType: LinearStateType
    var comments: [LinearThreadComment]
    var stateName: LinearState.Name? = nil
    var title: String = ""
    var description: String = ""
    var labels: [LinearLabel.Name] = []
    var teamId: LinearTeam.ID? = nil
    var projectId: LinearProject.ID? = nil
    var url: String? = nil
}

/// A comment of the owner's that a poll found by when it last changed,
/// with the issue it is on, if any.
struct OwnerCommentHit: Sendable, Equatable {
    var id: LinearComment.ID
    var body: String
    var issueId: LinearIssue.ID?
    var identifier: LinearIssue.Identifier?
    var teamId: LinearTeam.ID?
}

/// The spec document with its comments, oldest first.
struct DocumentComments: Sendable, Equatable {
    var id: LinearDocument.ID
    /// What a comment on the document is made on.
    var documentContentId: String?
    var content: String
    var updatedAt: Date
    var comments: [LinearThreadComment]
}

/// How superlinear tells its own comments from the owner's: they are written
/// with the owner's API key, so they have the owner as their user.
enum CommentMarker {
    /// The first line of every reply superlinear writes.
    static let line = "*Written by superlinear.*"

    /// The reply with its marker line.
    static func reply(_ text: String) -> String {
        "\(line)\n\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// Whether superlinear wrote the comment: a reply, or a proposal's
    /// comment or note, whose first lines are its own.
    static func isOwn(_ body: String) -> Bool {
        let first = body.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if first == line { return true }
        return first.firstMatch(of: /^\*\*(?:superlinear proposes|Superseded |Applied |Rejected |Expired |Not applied )/) != nil
    }
}

/// A comment of the owner's that superlinear has yet to handle: a new one,
/// or one whose text changed since, with the text it had then.
struct FreshComment: Sendable, Equatable {
    var comment: LinearThreadComment
    var previousBody: String?
}

/// What superlinear handled of the comments on one issue or document: which
/// comments, with the text each had then, and from when comments count at
/// all, so that old comments are not all answered at once after an upgrade.
struct CommentLedger: Codable, Sendable, Equatable {
    /// Which issue or document a ledger is for, as the state file keys it.
    typealias Key = Tagged<CommentLedger, String>

    /// Comments created at or before this time count only once handled.
    var since: Date
    /// The text of each comment handled, by comment ID.
    var handled: [LinearComment.ID: String] = [:]
    /// The requests for a change that wait for the issue's next agent, by
    /// comment ID.
    var waiting: [LinearComment.ID: WaitingComment] = [:]
    /// The comments given the 👀 reaction, so each gets it once.
    var reacted: Set<LinearComment.ID> = []
    /// When a comment was last handled, so that the ledger of an issue
    /// superlinear neither proposed nor works on is kept for a while, for
    /// edits to its comments.
    var handledAt: Date?

    init(since: Date) {
        self.since = since
    }

    // Ledgers from before comments on every issue were handled have no
    // waiting comments, reactions or time of handling.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        since = try container.decode(Date.self, forKey: .since)
        handled = try container.decodeIfPresent([LinearComment.ID: String].self, forKey: .handled) ?? [:]
        waiting = try container.decodeIfPresent([LinearComment.ID: WaitingComment].self, forKey: .waiting) ?? [:]
        reacted = try container.decodeIfPresent(Set<LinearComment.ID>.self, forKey: .reacted) ?? []
        handledAt = try container.decodeIfPresent(Date.self, forKey: .handledAt)
    }

    /// The owner's comments to handle: those by `viewer`, not superlinear's
    /// own, that are new since `since` and not yet handled, or whose text
    /// changed since they were. A change only to reactions does not count,
    /// and a request that waits for an agent with its text is not fresh.
    func fresh(_ comments: [LinearThreadComment], viewer: LinearUser.ID) -> [FreshComment] {
        comments.compactMap { comment in
            guard comment.userId == viewer, !CommentMarker.isOwn(comment.body) else { return nil }
            if waiting[comment.id]?.body == comment.body { return nil }
            if let body = handled[comment.id] {
                return body == comment.body ? nil : FreshComment(comment: comment, previousBody: body)
            }
            return comment.createdAt > since ? FreshComment(comment: comment) : nil
        }
    }

    /// The requests that wait for an agent, with the text they had when a
    /// session read them. One edited since is fresh instead.
    func waitingComments(_ comments: [LinearThreadComment]) -> [FreshComment] {
        comments.compactMap { comment in
            guard let waiting = waiting[comment.id], waiting.body == comment.body else { return nil }
            return FreshComment(comment: comment, previousBody: handled[comment.id])
        }
    }

    mutating func handle(_ comments: [FreshComment], at date: Date) {
        for fresh in comments {
            handled[fresh.comment.id] = fresh.comment.body
            waiting[fresh.comment.id] = nil
        }
        handledAt = max(handledAt ?? date, date)
    }

    /// Records the comments as requests that wait for the issue's next agent.
    mutating func wait(_ comments: [FreshComment], issue: LinearIssue.Identifier) {
        for fresh in comments {
            waiting[fresh.comment.id] = WaitingComment(body: fresh.comment.body, issue: issue, url: fresh.comment.url)
        }
    }
}

/// A request for a change that waits for an issue's next agent, as `superlinear
/// status` lists it.
struct WaitingComment: Codable, Sendable, Equatable {
    /// Its text when a session read it.
    var body: String
    /// The issue's identifier, such as `SPL-4`.
    var issue: LinearIssue.Identifier
    var url: String?

    /// The most characters of `summary`.
    static let summaryLength = 80

    /// Its first line, short, for the status: cut to `summaryLength`
    /// characters, an ellipsis last.
    var summary: String {
        let line = body.split(separator: "\n").first.map(String.init) ?? ""
        return line.count > Self.summaryLength ? String(line.prefix(Self.summaryLength - 1)) + "…" : line
    }
}

extension Tagged where Tag == CommentLedger, RawValue == String {
    /// The key of an issue's ledger: its ID.
    init(_ issueId: LinearIssue.ID) { self.init(rawValue: issueId.rawValue) }

    /// The key of the spec document's ledger.
    static func document(_ id: LinearDocument.ID) -> Self { Self(rawValue: "document:\(id.rawValue)") }

    /// Whether it is the key of a document's ledger, rather than an issue's.
    var isDocument: Bool { rawValue.hasPrefix("document:") }
}

/// An issue whose last agent ended with no pull request, and no Claude usage
/// limit stop, which is resumed instead. A comment from the owner queues a
/// new agent for it.
struct EndedAgent: Codable, Sendable, Equatable {
    var issueId: LinearIssue.ID
    var identifier: LinearIssue.Identifier
    var branchName: String
    /// When its last agent started, from which its comments count.
    var startedAt: Date?
}

/// The comments of an issue a run is given, for its prompt.
struct CommentContext: Codable, Sendable, Equatable {
    /// Every comment on the issue, oldest first.
    var thread: [PromptComment]
    /// The owner's comments the run is to act on: new ones, and edited ones
    /// with their earlier text.
    var new: [PromptComment] = []

    init(thread: [PromptComment], new: [PromptComment] = []) {
        self.thread = thread
        self.new = new
    }

    init(comments: [LinearThreadComment], fresh: [FreshComment] = []) {
        thread = comments.map { PromptComment($0) }
        new = fresh.map { PromptComment($0.comment, previousBody: $0.previousBody) }
    }
}

struct PromptComment: Codable, Sendable, Equatable {
    var author: String?
    var body: String
    var createdAt: Date
    /// The text it had when superlinear last handled it, for an edited one.
    var previousBody: String?

    init(author: String?, body: String, createdAt: Date, previousBody: String? = nil) {
        self.author = author
        self.body = body
        self.createdAt = createdAt
        self.previousBody = previousBody
    }

    init(_ comment: LinearThreadComment, previousBody: String? = nil) {
        self.init(author: comment.author, body: comment.body, createdAt: comment.createdAt, previousBody: previousBody)
    }
}

/// Where an issue stands, which decides what becomes of the owner's comment
/// on it.
enum IssueSituation: String, Codable, Sendable, Equatable {
    /// Open, and no agent of superlinear's works on it: not started, kept for
    /// a person with a `humanLabels` label, or started by hand. A request
    /// changes its description.
    case open
    /// An agent works on it now. A request waits for the next agent.
    case running
    /// Its agent ended and its pull request is open. A request goes to a
    /// review agent.
    case pullRequest
    /// Its agent ended without a pull request, and it is still started. A
    /// request goes to a new agent.
    case agentEnded
    /// Completed. A request becomes a `createIssue` proposal.
    case done
    /// Canceled, or a duplicate. A request becomes a `createIssue` proposal.
    case closed

    /// Whether a request for a change waits for an agent.
    var requestWaitsForAgent: Bool { [.running, .pullRequest, .agentEnded].contains(self) }

    /// Whether a request for a change becomes a new issue.
    var requestProposesIssue: Bool { [.done, .closed].contains(self) }
}

extension WorkspaceState {
    /// Where the issue stands now, from `planned`, where it stood when the
    /// poll found the comment: an agent may have started or ended on it since.
    func situation(of issueId: LinearIssue.ID, planned: IssueSituation) -> IssueSituation {
        if inFlight[issueId.rawValue] != nil { return .running }
        if planned == .running {
            if pendingMerges[issueId.rawValue] != nil { return .pullRequest }
            if endedAgents[issueId] != nil { return .agentEnded }
        }
        return planned
    }
}

/// What to do about the owner's comments on the issues of the watched teams,
/// found at a poll.
enum CommentTriage {
    /// What the daemon follows, as the poll reads it from the state file.
    struct Inputs: Sendable {
        var proposals: [Proposal]
        var pendingMerges: [PendingMerge]
        var ended: [EndedAgent]
        /// Runs queued or running, by issue ID.
        var runs: [AgentRun]
        var ledgers: [CommentLedger.Key: CommentLedger]
        /// Issues on which the poll found the owner's comments new or changed.
        var found: Set<LinearIssue.ID>
        /// From when the comments of an issue in `found` with no ledger count.
        var foundSince: Date?

        init(
            proposals: [Proposal], pendingMerges: [PendingMerge], ended: [EndedAgent], runs: [AgentRun],
            ledgers: [CommentLedger.Key: CommentLedger], found: Set<LinearIssue.ID>, foundSince: Date?
        ) {
            self.proposals = proposals
            self.pendingMerges = pendingMerges
            self.ended = ended
            self.runs = runs
            self.ledgers = ledgers
            self.found = found
            self.foundSince = foundSince
        }

        var posted: [Proposal] { proposals.filter(\.isPosted) }
    }

    /// A question or request on a pending proposal, for a read-only session.
    struct Answer: Sendable, Equatable {
        var proposal: Proposal
        var issueId: LinearIssue.ID
        var comment: FreshComment
        /// The comments before it that it may refer to: the proposed issue's,
        /// or the proposal comment's thread.
        var thread: [LinearThreadComment]
    }

    /// A comment on an issue, outside any proposal, for a read-only session
    /// that decides what it is.
    struct IssueAnswer: Sendable, Equatable {
        var issue: IssueComments
        var situation: IssueSituation
        var comment: FreshComment
        /// The comments of its thread before it, with it.
        var thread: [LinearThreadComment]
    }

    struct Plan: Sendable, Equatable {
        var answers: [Answer] = []
        var issueAnswers: [IssueAnswer] = []
        /// The owner's comments for a review agent, by issue ID.
        var reviews: [String: Comments] = [:]
        /// The owner's comments for a new agent on an issue whose agent
        /// ended without a pull request.
        var newAgents: [Comments] = []
        /// Ledgers for issues watched for the first time, with their baselines.
        var baselines: [CommentLedger.Key: CommentLedger] = [:]
        /// Every issue whose ledger is kept; the others' are dropped.
        var watched: Set<CommentLedger.Key> = []
        /// Ended agents whose issues were completed or canceled.
        var finished: Set<LinearIssue.ID> = []
        /// Why comments were skipped, one line each, for the log.
        var skipped: [String] = []
    }

    /// The owner's comments an agent is to act on, and the issue's comments
    /// for its prompt.
    struct Comments: Sendable, Equatable {
        var issueId: LinearIssue.ID
        var context: CommentContext
        var fresh: [FreshComment]
    }

    /// How long the ledger of an issue that superlinear neither proposed nor
    /// works on is kept after its last comment was handled, for edits.
    static let ledgerRetention: TimeInterval = 30 * 24 * 60 * 60

    /// How long the comments of an issue are read again each poll after its
    /// ledger was made or a comment on it handled, so that a comment still
    /// on the queue at a restart is found again.
    static let recentLedger: TimeInterval = 24 * 60 * 60

    private static func isRecent(_ ledger: CommentLedger, now: Date) -> Bool {
        max(ledger.since, ledger.handledAt ?? .distantPast) > now.addingTimeInterval(-recentLedger)
    }

    /// The issues whose comments to read: those of pending proposals in
    /// Linear, of agents awaiting a merge, of agents that ended without a
    /// pull request, those with requests that wait for an agent, those the
    /// poll found the owner's comments on, and those with recent ledgers.
    /// Issues with a run are left until it ends, unless a proposal waits on
    /// them or the owner commented. GitHub issues have no comments in Linear.
    static func issueIds(_ inputs: Inputs, now: Date) -> [LinearIssue.ID] {
        let running = Set(inputs.runs.map(\.issueId))
        let agents = inputs.pendingMerges.filter { GitHubIssue.number(ofIssueId: $0.issueId) == nil }
            .map { LinearIssue.ID(rawValue: $0.issueId) } + inputs.ended.map(\.issueId)
        let waiting = inputs.ledgers.filter { !$0.key.isDocument && !$0.value.waiting.isEmpty }
            .map { LinearIssue.ID(rawValue: $0.key.rawValue) }
        let recent = inputs.ledgers.filter { !$0.key.isDocument && isRecent($0.value, now: now) }
            .map { LinearIssue.ID(rawValue: $0.key.rawValue) }
        let ids = Set(inputs.posted.compactMap { $0.post?.issueId })
            .union((agents + waiting).filter { !running.contains($0.rawValue) })
            .union(inputs.found)
            .union(recent)
        return ids.sorted()
    }

    /// Where the issue stands, from what the daemon follows and its state.
    static func situation(_ issue: IssueComments, _ inputs: Inputs) -> IssueSituation {
        let id = issue.id.rawValue
        if inputs.runs.contains(where: { $0.issueId == id }) { return .running }
        if LinearStateType.closed.contains(issue.stateType) { return issue.stateType == .completed ? .done : .closed }
        if inputs.pendingMerges.contains(where: { $0.issueId == id }) { return .pullRequest }
        if issue.stateType == .started, inputs.ended.contains(where: { $0.issueId == issue.id }) { return .agentEnded }
        return .open
    }

    /// Sorts each issue's fresh comments from the owner: on a proposed issue,
    /// or in a proposal comment's thread, a question for a session on the
    /// proposal; any other, a session that decides what it is and acts by
    /// the issue's situation. Requests that wait for an agent go to the
    /// review agent of an issue whose agent awaits its merge, or to a new
    /// agent on a started issue whose agent ended without a pull request;
    /// they wait while a run goes on. `now` is the baseline of an issue with
    /// no proposal, agent start or finding to count from.
    static func plan(_ inputs: Inputs, issues: [IssueComments], viewer: LinearUser.ID, now: Date) -> Plan {
        var plan = Plan()
        let running = Set(inputs.runs.map(\.issueId))

        // Baselines: the issue's last proposal post or agent start, or for
        // an issue the poll found comments on, when it looked from.
        var starts: [CommentLedger.Key: Date] = [:]
        func start(_ id: CommentLedger.Key, _ date: Date?) {
            let date = date ?? now
            starts[id] = max(starts[id] ?? .distantPast, date)
        }
        for proposal in inputs.posted { if let post = proposal.post { start(.init(post.issueId), post.postedAt) } }
        for pending in inputs.pendingMerges { start(.init(rawValue: pending.issueId), pending.reviewsHandledThrough) }
        for ended in inputs.ended { start(.init(ended.issueId), ended.startedAt) }
        for run in inputs.runs { start(.init(rawValue: run.issueId), run.launchedAt ?? run.queuedAt) }
        for id in inputs.found where starts[.init(id)] == nil { start(.init(id), inputs.foundSince) }
        plan.watched = Set(starts.keys)
        for (key, ledger) in inputs.ledgers where !ledger.waiting.isEmpty || isRecent(ledger, now: now)
            || (ledger.handledAt.map { now.timeIntervalSince($0) < ledgerRetention } ?? false) {
            plan.watched.insert(key)
        }
        for (id, date) in starts where inputs.ledgers[id] == nil { plan.baselines[id] = CommentLedger(since: date) }
        func ledger(_ id: CommentLedger.Key) -> CommentLedger { inputs.ledgers[id] ?? plan.baselines[id] ?? CommentLedger(since: now) }

        // Proposal comments, whose threads are the proposals' own.
        var proposalThreads: Set<LinearComment.ID> = []
        var proposals: [LinearIssue.ID: Proposal] = [:]
        for proposal in inputs.posted {
            guard let post = proposal.post else { continue }
            if let commentId = post.commentId { proposalThreads.insert(commentId) } else { proposals[post.issueId] = proposal }
        }

        for proposal in inputs.posted {
            guard let post = proposal.post, let commentId = post.commentId, let issue = issues.first(where: { $0.id == post.issueId })
            else { continue }
            let thread = issue.comments.filter { $0.id == commentId || $0.parentId == commentId }
            for comment in fresh(issue, ledger(.init(post.issueId)), viewer: viewer) where comment.comment.parentId == commentId {
                plan.answers.append(Answer(proposal: proposal, issueId: post.issueId, comment: comment, thread: before(comment, in: thread)))
            }
        }

        let proposedIssues = Set(proposals.keys.map(\.rawValue))
        for issue in issues {
            let key = CommentLedger.Key(issue.id)
            let ledger = ledger(key)
            plan.skipped += skipped(issue, ledger, viewer: viewer)
            let fresh = fresh(issue, ledger, viewer: viewer).filter { !proposalThreads.contains($0.comment.rootId) }

            // A proposed issue's comments are all about its proposal.
            if let proposal = proposals[issue.id] {
                for comment in fresh {
                    plan.answers.append(Answer(proposal: proposal, issueId: issue.id, comment: comment, thread: before(comment, in: issue.comments)))
                }
                continue
            }

            let situation = situation(issue, inputs)
            for comment in fresh { plan.issueAnswers.append(issueAnswer(issue, situation, comment)) }

            let waiting = ledger.waitingComments(issue.comments)
            guard !waiting.isEmpty, !running.contains(issue.id.rawValue) else { continue }
            let comments = Comments(issueId: issue.id, context: CommentContext(comments: issue.comments, fresh: waiting), fresh: waiting)
            switch situation {
            case .pullRequest where !proposedIssues.contains(issue.id.rawValue):
                plan.reviews[issue.id.rawValue] = comments
            case .agentEnded:
                plan.newAgents.append(comments)
            case .running, .pullRequest:
                break
            case .open, .done, .closed:
                // Its agent's work ended otherwise: a session reads it again.
                for comment in waiting {
                    plan.issueAnswers.append(issueAnswer(issue, situation, FreshComment(comment: comment.comment)))
                }
            }
        }

        let byId = Dictionary(issues.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for ended in inputs.ended where !running.contains(ended.issueId.rawValue) {
            if let issue = byId[ended.issueId], LinearStateType.closed.contains(issue.stateType) { plan.finished.insert(ended.issueId) }
        }
        return plan
    }

    /// The fresh comments of an issue, but for an issue watched for the first
    /// time, not those superlinear replied to already: their ledger may have
    /// been dropped when the issue was last watched.
    private static func fresh(_ issue: IssueComments, _ ledger: CommentLedger, viewer: LinearUser.ID) -> [FreshComment] {
        let fresh = ledger.fresh(issue.comments, viewer: viewer)
        guard ledger.handled.isEmpty else { return fresh }
        return fresh.filter { comment in
            !issue.comments.contains {
                $0.rootId == comment.comment.rootId && $0.createdAt > comment.comment.createdAt && CommentMarker.isOwn($0.body)
            }
        }
    }

    /// Lines for the log about other users' comments since the baseline,
    /// which are left alone.
    private static func skipped(_ issue: IssueComments, _ ledger: CommentLedger, viewer: LinearUser.ID) -> [String] {
        issue.comments.filter { $0.userId != viewer && $0.createdAt > ledger.since && !CommentMarker.isOwn($0.body) }.map {
            "Skipping \($0.author ?? "another user")'s comment \($0.id) on \(issue.identifier): only the owner's comments are handled"
        }
    }

    private static func issueAnswer(_ issue: IssueComments, _ situation: IssueSituation, _ comment: FreshComment) -> IssueAnswer {
        let thread = issue.comments.filter { $0.rootId == comment.comment.rootId }
        return IssueAnswer(issue: issue, situation: situation, comment: comment, thread: before(comment, in: thread))
    }

    /// The comments of `thread` that a session answering `comment` is shown:
    /// those written before it, and the comment itself, but none after it,
    /// so the session answers the comment as it was asked, not later ones.
    private static func before(_ comment: FreshComment, in thread: [LinearThreadComment]) -> [LinearThreadComment] {
        thread.filter { $0.createdAt < comment.comment.createdAt || $0.id == comment.comment.id }
    }

    /// The issues to read for the owner's comments that a poll found, and
    /// lines for the log about those skipped: superlinear's own, and those
    /// on no issue or on an issue of a team not watched. On the first poll
    /// after the upgrade, `backfill`, comments on issues superlinear proposed
    /// or worked on, `excluded`, are left out: the old rule handled those.
    static func found(
        _ hits: [OwnerCommentHit], teamIds: [LinearTeam.ID], backfill: Bool, excluded: Set<LinearIssue.ID>
    ) -> (issueIds: Set<LinearIssue.ID>, skipped: [String]) {
        var ids: Set<LinearIssue.ID> = []
        var skipped: [String] = []
        let watched = Set(teamIds)
        for hit in hits where !CommentMarker.isOwn(hit.body) {
            guard let issueId = hit.issueId else { continue }
            if !watched.isEmpty, !(hit.teamId.map(watched.contains) ?? false) {
                skipped.append("Skipping the owner's comment \(hit.id) on \(hit.identifier?.rawValue ?? issueId.rawValue): its team is not watched")
                continue
            }
            if backfill, excluded.contains(issueId) { continue }
            ids.insert(issueId)
        }
        return (ids, skipped)
    }

    /// From when the owner's comments count on the first poll after the
    /// upgrade: when superlinear first kept a comment ledger in the
    /// workspace, or `now` when it has none.
    static func backfillStart(_ ledgers: [CommentLedger.Key: CommentLedger], now: Date) -> Date {
        ledgers.values.map(\.since).min() ?? now
    }
}
