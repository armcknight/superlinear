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

/// An issue with its comments, oldest first, as a poll reads them.
struct IssueComments: Sendable, Equatable {
    var id: LinearIssue.ID
    var identifier: String
    var stateType: LinearStateType
    var comments: [LinearThreadComment]
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

    /// The owner's comments to handle: those by `viewer`, not superlinear's
    /// own, that are new since `since` and not yet handled, or whose text
    /// changed since they were. A change only to reactions does not count.
    func fresh(_ comments: [LinearThreadComment], viewer: LinearUser.ID) -> [FreshComment] {
        comments.compactMap { comment in
            guard comment.userId == viewer, !CommentMarker.isOwn(comment.body) else { return nil }
            if let body = handled[comment.id] {
                return body == comment.body ? nil : FreshComment(comment: comment, previousBody: body)
            }
            return comment.createdAt > since ? FreshComment(comment: comment) : nil
        }
    }

    mutating func handle(_ comments: [FreshComment]) {
        for fresh in comments { handled[fresh.comment.id] = fresh.comment.body }
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

/// What to do about the owner's comments on the issues superlinear proposed
/// or works on, found at a poll.
enum CommentTriage {
    /// What the daemon follows, as the poll reads it from the state file.
    struct Inputs: Sendable {
        var proposals: [Proposal]
        var pendingMerges: [PendingMerge]
        var ended: [EndedAgent]
        /// Runs queued or running, by issue ID.
        var runs: [AgentRun]
        var ledgers: [CommentLedger.Key: CommentLedger]

        init(
            proposals: [Proposal] = [], pendingMerges: [PendingMerge] = [], ended: [EndedAgent] = [], runs: [AgentRun] = [],
            ledgers: [CommentLedger.Key: CommentLedger] = [:]
        ) {
            self.proposals = proposals
            self.pendingMerges = pendingMerges
            self.ended = ended
            self.runs = runs
            self.ledgers = ledgers
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

    struct Plan: Sendable, Equatable {
        var answers: [Answer] = []
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
    }

    /// The owner's comments an agent is to act on, and the issue's comments
    /// for its prompt.
    struct Comments: Sendable, Equatable {
        var issueId: LinearIssue.ID
        var context: CommentContext
        var fresh: [FreshComment]
    }

    /// The issues whose comments to read: those of pending proposals in
    /// Linear, of agents awaiting a merge, and of agents that ended without a
    /// pull request. Issues with a run are left until it ends, unless a
    /// proposal waits on them.
    static func issueIds(_ inputs: Inputs) -> [LinearIssue.ID] {
        let running = Set(inputs.runs.map(\.issueId))
        let agents = inputs.pendingMerges.map { LinearIssue.ID(rawValue: $0.issueId) } + inputs.ended.map(\.issueId)
        let ids = Set(inputs.posted.compactMap { $0.post?.issueId }).union(agents.filter { !running.contains($0.rawValue) })
        return ids.sorted()
    }

    /// Sorts each issue's fresh comments from the owner: on a proposed issue,
    /// or in a proposal comment's thread, a question for a session; on an
    /// issue whose agent awaits its merge, a review agent; on a started issue
    /// whose agent ended without a pull request, a new agent. Issues with a
    /// run wait for it to end. `now` is the baseline of an issue with no
    /// proposal or agent start to count from.
    static func plan(_ inputs: Inputs, issues: [IssueComments], viewer: LinearUser.ID, now: Date) -> Plan {
        var plan = Plan()
        let byId = Dictionary(issues.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let running = Set(inputs.runs.map(\.issueId))

        // Baselines: the issue's last proposal post or agent start.
        var starts: [CommentLedger.Key: Date] = [:]
        func start(_ id: CommentLedger.Key, _ date: Date?) {
            let date = date ?? now
            starts[id] = max(starts[id] ?? .distantPast, date)
        }
        for proposal in inputs.posted { if let post = proposal.post { start(.init(post.issueId), post.postedAt) } }
        for pending in inputs.pendingMerges { start(.init(rawValue: pending.issueId), pending.reviewsHandledThrough) }
        for ended in inputs.ended { start(.init(ended.issueId), ended.startedAt) }
        for run in inputs.runs { start(.init(rawValue: run.issueId), run.launchedAt ?? run.queuedAt) }
        plan.watched = Set(starts.keys)
        for (id, date) in starts where inputs.ledgers[id] == nil { plan.baselines[id] = CommentLedger(since: date) }
        func ledger(_ id: CommentLedger.Key) -> CommentLedger { inputs.ledgers[id] ?? plan.baselines[id] ?? CommentLedger(since: now) }

        // Proposal comments, whose threads are the proposals' own.
        var proposalThreads: [String: Proposal] = [:]
        for proposal in inputs.posted {
            if let commentId = proposal.post?.commentId { proposalThreads[commentId.rawValue] = proposal }
        }

        for proposal in inputs.posted {
            guard let post = proposal.post, let issue = byId[post.issueId] else { continue }
            let fresh = ledger(.init(post.issueId)).fresh(issue.comments, viewer: viewer)
            let thread: [LinearThreadComment]
            let asked: [FreshComment]
            if let commentId = post.commentId {
                thread = issue.comments.filter { $0.id == commentId || $0.parentId == commentId }
                asked = fresh.filter { $0.comment.parentId == commentId }
            } else {
                thread = issue.comments
                asked = fresh
            }
            for comment in asked {
                let before = thread.filter { $0.createdAt < comment.comment.createdAt || $0.id == comment.comment.id }
                plan.answers.append(Answer(proposal: proposal, issueId: post.issueId, comment: comment, thread: before))
            }
        }

        let proposedIssues = Set(inputs.posted.compactMap { $0.post?.isIssue == true ? $0.post?.issueId.rawValue : nil })
        func agentComments(_ issue: IssueComments) -> [FreshComment] {
            ledger(.init(issue.id)).fresh(issue.comments, viewer: viewer).filter { fresh in
                proposalThreads[fresh.comment.rootId.rawValue] == nil
            }
        }

        for pending in inputs.pendingMerges {
            let id = LinearIssue.ID(rawValue: pending.issueId)
            guard !running.contains(pending.issueId), !proposedIssues.contains(pending.issueId), let issue = byId[id] else { continue }
            let fresh = agentComments(issue)
            guard !fresh.isEmpty else { continue }
            plan.reviews[pending.issueId] = Comments(issueId: id, context: CommentContext(comments: issue.comments, fresh: fresh), fresh: fresh)
        }

        for ended in inputs.ended {
            guard !running.contains(ended.issueId.rawValue), let issue = byId[ended.issueId] else { continue }
            if [.completed, .canceled].contains(issue.stateType) {
                plan.finished.insert(ended.issueId)
                continue
            }
            guard issue.stateType == .started else { continue }
            let fresh = agentComments(issue)
            guard !fresh.isEmpty else { continue }
            plan.newAgents.append(Comments(issueId: ended.issueId, context: CommentContext(comments: issue.comments, fresh: fresh), fresh: fresh))
        }
        return plan
    }
}
