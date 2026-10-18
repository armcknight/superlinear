import Foundation
import Tagged

/// The kinds of change superlinear can propose to a Linear workspace. Each
/// has its own trust level in the workspace's `autonomy` config.
enum ProposalKind: String, Codable, Sendable, CaseIterable {
    case createIssue
    case editIssue
    case closeIssue
    case addRelation
    /// Moves an issue from Backlog to Todo, as when its blockers are done.
    case promoteIssue
    /// Rewrites a project's description or a document.
    case changeSpec
    case postProjectUpdate
}

/// How far superlinear may go on its own with a kind of proposal.
enum TrustLevel: String, Codable, Sendable {
    /// Applied at once, and still listed for review.
    case auto
    /// Put in Linear for the owner to approve or reject there.
    case review
    /// Never proposed.
    case never

    /// Configs and state files from before proposals were reviewed in Linear
    /// name `review` after the command that once showed them.
    static let formerReviewName = "standup"

    init(from decoder: Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        guard let level = TrustLevel(rawValue: name == Self.formerReviewName ? TrustLevel.review.rawValue : name) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown trust level \"\(name)\". Known levels: auto, review, never"))
        }
        self = level
    }
}

/// The trust level of each kind of proposal in a workspace: the config's
/// `autonomy` map over the defaults, where only `addRelation` is `auto`.
struct Autonomy: Sendable, Equatable {
    static let defaults: [ProposalKind: TrustLevel] = Dictionary(
        uniqueKeysWithValues: ProposalKind.allCases.map { ($0, $0 == .addRelation ? .auto : .review) }
    )

    var levels: [ProposalKind: TrustLevel] = Autonomy.defaults

    init(overrides: [ProposalKind: TrustLevel] = [:]) {
        levels.merge(overrides) { _, override in override }
    }

    func level(for kind: ProposalKind) -> TrustLevel {
        levels[kind] ?? .review
    }
}

/// What a proposal changes, by its ID in Linear. A new issue's target is its
/// team. `name` is what a person calls it, such as `SPL-4` or the project's
/// name.
enum ProposalTarget: Codable, Sendable, Equatable, Hashable {
    case issue(LinearIssue.ID, name: String? = nil)
    case project(LinearProject.ID, name: String? = nil)
    case document(LinearDocument.ID, name: String? = nil)
    case team(LinearTeam.ID, name: String? = nil)

    enum Kind: String, Codable, Sendable {
        case issue, project, document, team
    }

    var kind: Kind {
        switch self {
        case .issue: .issue
        case .project: .project
        case .document: .document
        case .team: .team
        }
    }

    /// The ID without its tag, for showing and comparing across kinds.
    var rawID: String {
        switch self {
        case .issue(let id, _): id.rawValue
        case .project(let id, _): id.rawValue
        case .document(let id, _): id.rawValue
        case .team(let id, _): id.rawValue
        }
    }

    var name: String? {
        switch self {
        case .issue(_, let name), .project(_, let name), .document(_, let name), .team(_, let name): name
        }
    }

    // Kept as `{kind, id, name}` in the state file.
    private enum CodingKeys: String, CodingKey {
        case kind, id, name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let name = try container.decodeIfPresent(String.self, forKey: .name)
        self = switch try container.decode(Kind.self, forKey: .kind) {
        case .issue: .issue(LinearIssue.ID(rawValue: id), name: name)
        case .project: .project(LinearProject.ID(rawValue: id), name: name)
        case .document: .document(LinearDocument.ID(rawValue: id), name: name)
        case .team: .team(LinearTeam.ID(rawValue: id), name: name)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(rawID, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
    }
}

/// Where a proposal came from, so the owner can judge it, and so issues
/// superlinear creates can link back to it.
struct ProposalSource: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case pullRequest, commitRange, agentSession, workflowRun
        /// A comment of the owner's in Linear, such as on the spec document.
        case comment
    }

    var kind: Kind
    /// The pull request URL, the commit range such as `abc123..def456`, the
    /// agent's session ID, the workflow run's URL, or the comment's URL.
    var value: String
    /// A link to the commit range or the session, when there is one. A pull
    /// request's or a workflow run's value is its link.
    var url: String?
    /// The issue the agent or pull request worked on, such as `SPL-4`.
    var issue: LinearIssue.Identifier?
    /// The agent's pull request, when the source is an agent session.
    var pullRequest: String?

    init(kind: Kind, value: String, url: String? = nil, issue: LinearIssue.Identifier? = nil, pullRequest: String? = nil) {
        self.kind = kind
        self.value = value
        self.url = url
        self.issue = issue
        self.pullRequest = pullRequest
    }

    var link: String? { [.pullRequest, .workflowRun, .comment].contains(kind) ? value : url }

    /// The line added to what superlinear writes, saying where it came from.
    var line: String {
        let text = switch kind {
        case .pullRequest: value
        case .commitRange: "commits \(value)"
        case .agentSession: "agent session \(value)"
        case .workflowRun: value
        case .comment: "a comment"
        }
        var source = if let link, link != text { "[\(text)](\(link))" } else { text }
        if let issue { source += " for \(issue)" }
        if let pullRequest, pullRequest != link { source += ", \(pullRequest)" }
        return "Source: \(source)"
    }
}

/// The change itself. An edit carries the old and the new text, so that a
/// diff can be shown. For an issue superlinear did not create, they are the
/// text of its managed block, not of the whole description.
enum ProposalPayload: Codable, Sendable, Equatable {
    /// `relatedIssueId` is the issue the new one follows from, if any. Should
    /// an open issue like the new one exist already, a relation to it is
    /// proposed instead.
    case createIssue(
        teamId: LinearTeam.ID, projectId: LinearProject.ID?, title: String, description: String,
        relatedIssueId: LinearIssue.ID?
    )
    case editIssue(oldText: String, newText: String)
    case closeIssue
    /// `type` is one of Linear's relation types: `blocks`, `duplicate`,
    /// `related` or `similar`. The target is the relation's first issue.
    case addRelation(relatedIssueId: LinearIssue.ID, type: String)
    case promoteIssue
    case changeSpec(oldText: String, newText: String)
    /// `overviewIssueId` is the project's overview issue, on which the update
    /// is proposed as a comment when its kind is not `auto`.
    case postProjectUpdate(body: String, overviewIssueId: LinearIssue.ID? = nil)

    var kind: ProposalKind {
        switch self {
        case .createIssue: .createIssue
        case .editIssue: .editIssue
        case .closeIssue: .closeIssue
        case .addRelation: .addRelation
        case .promoteIssue: .promoteIssue
        case .changeSpec: .changeSpec
        case .postProjectUpdate: .postProjectUpdate
        }
    }
}

/// A change before it is stored: what a producer, such as the planning job or
/// an agent's follow-ups, hands over.
struct ProposalDraft: Sendable, Equatable {
    var payload: ProposalPayload
    var target: ProposalTarget
    var reason: String
    var source: ProposalSource
    /// The target's `updatedAt` when the change was worked out. Should the
    /// target change after it, the proposal is not applied, but waits for
    /// review again.
    var targetUpdatedAt: Date?
}

/// Where a pending proposal is shown in Linear, and from when. The owner
/// answers it there: an issue is accepted or declined, a comment reacted to.
struct ProposalPost: Codable, Sendable, Equatable {
    enum Form: String, Codable, Sendable {
        /// An issue superlinear created in its team's Triage state.
        case triageIssue
        /// An issue superlinear created in Backlog, for a team with Triage off.
        case backlogIssue
        /// A comment on the target issue, answered with a reaction.
        case comment
    }

    var form: Form
    /// The issue created, or the issue the comment is on.
    var issueId: LinearIssue.ID
    var issueIdentifier: String?
    /// The comment, for a `comment`.
    var commentId: LinearComment.ID?
    /// A link to the issue or the comment.
    var url: String?
    /// When it was put in Linear. Expiry counts from then.
    var postedAt: Date

    /// Whether the proposal is an issue of its own in Linear.
    var isIssue: Bool { form != .comment }
}

/// A proposed change to Linear, kept in the state file from when it is made
/// until it expires or long after it is decided.
struct Proposal: Codable, Sendable, Equatable, Identifiable {
    typealias ID = Tagged<Proposal, String>

    enum Status: String, Codable, Sendable {
        case pending, applied, rejected, expired
    }

    var id: ID
    var payload: ProposalPayload
    var target: ProposalTarget
    var reason: String
    var source: ProposalSource
    var createdAt: Date
    var status: Status
    /// The trust level when it was made, or `review` once a change in
    /// Linear sent it back for review.
    var trust: TrustLevel
    var targetUpdatedAt: Date?
    /// When it was applied, rejected or expired.
    var decidedAt: Date?
    var rejectionReason: String?
    /// Why it waits for review again, such as the target having changed in
    /// Linear since it was proposed.
    var reviewNote: String?
    /// The last failure to apply it. It stays pending.
    var lastError: String?
    /// Where it waits in Linear, once put there. A pending proposal without
    /// one is yet to be posted; state files from before proposals were
    /// reviewed in Linear have none.
    var post: ProposalPost?

    /// Whether it waits for the owner's answer in Linear.
    var isPosted: Bool { status == .pending && post != nil }

    var kind: ProposalKind { payload.kind }

    init(_ draft: ProposalDraft, trust: TrustLevel, id: ID = ID(rawValue: UUID().uuidString.lowercased()), now: Date = Date()) {
        self.id = id
        payload = draft.payload
        target = draft.target
        reason = draft.reason
        source = draft.source
        createdAt = now
        status = .pending
        self.trust = trust
        targetUpdatedAt = draft.targetUpdatedAt
    }

    /// What makes two proposals the same, for refusing one rejected or
    /// pending already: the kind and target, and for a new issue its title,
    /// for a relation the other issue, since one team or issue gets many.
    var sameness: String { Self.sameness(payload, target) }

    static func sameness(_ payload: ProposalPayload, _ target: ProposalTarget) -> String {
        var key = "\(payload.kind.rawValue) \(target.kind.rawValue):\(target.rawID)"
        switch payload {
        case .createIssue(_, _, let title, _, _):
            key += " " + TitleMatch.normalized(title)
        case .addRelation(let relatedIssueId, let type):
            key += " \(type) \(relatedIssueId)"
        default:
            break
        }
        return key
    }
}

/// Whether two issue titles name the same work: equal once case, punctuation
/// and spacing are set aside, or close by the Sørensen–Dice coefficient of
/// their letter pairs, which forgives plurals and small rewordings.
///
/// TODO: SPL-24. A title match misses the same intent in other words; an
/// agent is to find such duplicates and propose them for review.
enum TitleMatch {
    static let closeness = 0.8

    static func normalized(_ title: String) -> String {
        title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func isClose(_ a: String, _ b: String) -> Bool {
        similarity(a, b) >= closeness
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        let (a, b) = (normalized(a), normalized(b))
        if a == b { return 1 }
        let (pairsA, pairsB) = (bigrams(a), bigrams(b))
        guard !pairsA.isEmpty, !pairsB.isEmpty else { return 0 }
        let shared = pairsA.reduce(0) { sum, entry in sum + min(entry.value, pairsB[entry.key] ?? 0) }
        let total = pairsA.values.reduce(0, +) + pairsB.values.reduce(0, +)
        return Double(2 * shared) / Double(total)
    }

    private static func bigrams(_ text: String) -> [String: Int] {
        let characters = Array(text)
        guard characters.count > 1 else { return [:] }
        var pairs: [String: Int] = [:]
        for index in 0..<(characters.count - 1) {
            pairs[String(characters[index...index + 1]), default: 0] += 1
        }
        return pairs
    }
}

/// The part of an issue's description that superlinear may change in an issue
/// it did not create, between two HTML comments that Linear does not show.
enum ManagedBlock {
    static let start = "<!-- superlinear -->"
    static let end = "<!-- /superlinear -->"

    /// The text between the markers, or nil when there are none.
    static func contents(of description: String) -> String? {
        guard let range = innerRange(in: description) else { return nil }
        return description[range].trimmingCharacters(in: .newlines)
    }

    /// `description` with the block's text replaced by `text`, or with a block
    /// holding it added at the end. Text outside the block is kept as it is.
    static func replacing(in description: String, with text: String) -> String {
        if let range = innerRange(in: description) {
            return description.replacingCharacters(in: range, with: "\n\(text)\n")
        }
        let block = "\(start)\n\(text)\n\(end)"
        let kept = description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : description
        guard !kept.isEmpty else { return block }
        return kept + (kept.hasSuffix("\n") ? "\n" : "\n\n") + block
    }

    private static func innerRange(in description: String) -> Range<String.Index>? {
        guard let opening = description.range(of: start),
              let closing = description.range(of: end, range: opening.upperBound..<description.endIndex)
        else { return nil }
        return opening.upperBound..<closing.lowerBound
    }
}
