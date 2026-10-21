import Foundation

/// An issue as an edit needs it: its text, labels and when it last changed.
struct EditableIssue: Sendable, Equatable {
    var id: LinearIssue.ID
    var identifier: String
    var description: String
    var updatedAt: Date
    var labels: [String]
    var stateType: LinearStateType
    var teamId: LinearTeam.ID

    /// Whether superlinear created it, as its label says.
    var createdBySuperlinear: Bool { labels.contains { $0.caseInsensitiveCompare(ProposalEngine.label) == .orderedSame } }

    var handsOff: Bool { labels.contains { $0.caseInsensitiveCompare(ProposalEngine.handsOffLabel) == .orderedSame } }
}

/// An open issue that Linear's search found for a new one's title, which
/// may be the same work.
struct IssueMatch: Sendable, Equatable {
    var id: LinearIssue.ID
    var identifier: String
    var title: String
    var description: String = ""
    var url: String?
}

/// A project's description or a document, as a spec change needs it.
struct SpecText: Sendable, Equatable {
    var content: String
    var updatedAt: Date
}

/// A team's workflow states, as a new issue needs them to find Triage or
/// Backlog.
struct TeamStates: Sendable, Equatable {
    struct State: Sendable, Equatable {
        var id: LinearState.ID
        var type: LinearStateType
        var position: Double
    }

    var triageEnabled: Bool
    var states: [State]

    /// The first state of `type`, by position.
    func first(_ type: LinearStateType) -> State? {
        states.filter { $0.type == type }.min { $0.position < $1.position }
    }
}

/// What Linear answered when an issue was created.
struct CreatedIssue: Sendable, Equatable {
    var id: LinearIssue.ID
    var identifier: String
    var url: String?
    var response: JSONValue
}

/// What a comment is made on.
enum CommentTarget: Sendable, Equatable {
    case issue(LinearIssue.ID)
    /// A document, by its content's ID.
    case document(contentId: String)
}

/// What Linear answered when a comment was created.
struct CreatedComment: Sendable, Equatable {
    var id: LinearComment.ID
    var url: String?
    var response: JSONValue
}

/// An issue a proposal waits on, as a poll reads it: where it is, its labels,
/// and its comments with their reactions.
struct ProposalIssueSnapshot: Sendable, Equatable {
    struct Comment: Sendable, Equatable {
        var id: LinearComment.ID
        var reactions: [Reaction]
    }

    struct Reaction: Sendable, Equatable {
        /// The emoji, as Linear names it: `👍`, `+1` or `thumbsup`, with or
        /// without a skin tone.
        var emoji: String
        var userId: LinearUser.ID?
    }

    var id: LinearIssue.ID
    var identifier: String
    var stateType: LinearStateType
    var labels: [String]
    var comments: [Comment]
    /// The issue it is marked a duplicate of, when it is.
    var duplicateOf: Related?

    struct Related: Sendable, Equatable {
        var id: LinearIssue.ID
        var identifier: String
    }
}

/// The reads and writes in Linear that proposals need. `LinearClient` does
/// them for real; tests stand in for it. Each write returns Linear's response.
protocol LinearWriting: Sendable {
    /// The user the API key belongs to, whose reactions answer proposals.
    func viewerId() async throws -> LinearUser.ID
    func editableIssue(id: LinearIssue.ID) async throws -> EditableIssue
    /// Open issues in the team that Linear's search finds for `title`, with
    /// their descriptions.
    func openIssues(like title: String, teamId: LinearTeam.ID) async throws -> [IssueMatch]
    /// The ID of the label with this name in the team or the workspace,
    /// created in the team when there is none.
    func labelId(named name: String, teamId: LinearTeam.ID) async throws -> LinearLabel.ID
    func teamStates(id: LinearTeam.ID) async throws -> TeamStates
    /// Turns on Triage for the team. Throws when the API key may not.
    func enableTriage(teamId: LinearTeam.ID) async throws
    /// Creates an issue, in the team's default state when `stateId` is nil.
    func createIssue(
        teamId: LinearTeam.ID, projectId: LinearProject.ID?, title: String, description: String,
        labelIds: [LinearLabel.ID], stateId: LinearState.ID?
    ) async throws -> CreatedIssue
    func updateIssueDescription(id: LinearIssue.ID, description: String) async throws -> JSONValue
    /// Moves the issue to its team's first canceled state.
    func closeIssue(id: LinearIssue.ID) async throws -> JSONValue
    /// Moves the issue to its team's first unstarted state, such as Todo.
    func promoteIssue(id: LinearIssue.ID) async throws -> JSONValue
    /// Moves the issue to its team's first completed state. Returns false
    /// when it was completed or canceled already.
    func completeIssue(id: LinearIssue.ID) async throws -> Bool
    /// Moves the issue to its team's first state of `type`.
    func moveIssue(id: LinearIssue.ID, toFirst type: LinearStateType) async throws -> JSONValue
    func createRelation(issueId: LinearIssue.ID, relatedIssueId: LinearIssue.ID, type: String) async throws -> JSONValue
    func createComment(issueId: LinearIssue.ID, body: String) async throws -> CreatedComment
    func updateComment(id: LinearComment.ID, body: String) async throws -> JSONValue
    /// A reply in the thread whose first comment is `parentId`.
    func createReply(on target: CommentTarget, parentId: LinearComment.ID, body: String) async throws -> CreatedComment
    /// Reacts to the comment with the emoji of that name, such as `eyes`.
    func addReaction(commentId: LinearComment.ID, emoji: String) async throws -> JSONValue
    func addLabel(issueId: LinearIssue.ID, labelId: LinearLabel.ID) async throws -> JSONValue
    func removeLabel(issueId: LinearIssue.ID, labelId: LinearLabel.ID) async throws -> JSONValue
    /// The issues with these IDs, with their comments and reactions. Issues
    /// Linear no longer has, as when deleted or archived, are absent.
    func proposalIssues(ids: [LinearIssue.ID]) async throws -> [ProposalIssueSnapshot]
    func spec(of target: ProposalTarget) async throws -> SpecText
    func updateSpec(of target: ProposalTarget, content: String) async throws -> JSONValue
    func postProjectUpdate(projectId: LinearProject.ID, body: String) async throws -> JSONValue
}

enum ProposalError: Error, CustomStringConvertible {
    case unsupportedTarget(ProposalKind, ProposalTarget.Kind)

    var description: String {
        switch self {
        case .unsupportedTarget(let kind, let target): "A \(kind.rawValue) proposal cannot target a \(target.rawValue)"
        }
    }
}

/// Decides what becomes of a proposal: whether it is stored, whether it is
/// applied at once, and what applying it writes to Linear.
struct ProposalEngine: Sendable {
    /// The label on each issue superlinear creates. Such an issue's whole
    /// description is superlinear's to edit.
    static let label = "superlinear"
    /// An issue with this label is never changed.
    static let handsOffLabel = "superlinear: hands off"
    /// The label on each issue that holds a pending proposal: one superlinear
    /// created to propose, or one with a proposal's comment.
    static let proposedLabel = "superlinear: proposed"
    /// The label on an issue that proposes a spec change.
    static let specLabel = "superlinear: spec"
    /// The state file keeps dates to the second, and Linear to the
    /// millisecond, so an `updatedAt` within this much of the one proposed
    /// counts as the same.
    static let updatedAtTolerance: TimeInterval = 1

    let workspace: String
    let autonomy: Autonomy
    let linear: any LinearWriting
    let audit: AuditLog
    /// Decides whether a new issue is the same work as an open issue or a
    /// proposal.
    let duplicates: any DuplicateJudging

    enum Screening: Equatable {
        /// Store this proposal, and apply it at once when `applyNow`.
        case store(Proposal, applyNow: Bool)
        /// Keep this pending proposal, not yet in Linear, in place of the one
        /// with its ID: a new issue that repeats it merged into it.
        case merge(Proposal)
        case skip(reason: String)
    }

    /// What to do with `draft`, given the workspace's proposals so far.
    ///
    /// A new issue is first compared with the open issues that Linear's
    /// search finds for its title, and with the team's pending and rejected
    /// proposed issues, by `duplicates`. One that is the same work as an
    /// open issue becomes an edit that adds what it says to that issue; when
    /// it adds nothing, a relation between that issue and the one the new
    /// one follows from, or nothing when it follows from none. One that is
    /// the same work as a pending proposal not yet in Linear is merged into
    /// it, and one the same as a rejected proposal is not proposed. One that
    /// may be the same work as some candidates is proposed for review, with
    /// them listed; so is each when they could not be compared.
    func screen(_ draft: ProposalDraft, existing: [Proposal], now: Date = Date()) async throws -> Screening {
        // Before Linear's search, which a draft made again each poll, such
        // as one for a failing workflow, would otherwise repeat.
        if let repeated = Self.repeated(draft, in: existing) { return repeated }
        var draft = draft
        var possibleDuplicates: [PossibleDuplicate] = []
        if case .createIssue(let teamId, _, let title, let description, _) = draft.payload {
            let matches = try await linear.openIssues(like: title, teamId: teamId)
            let candidates = DuplicateCandidate.gather(teamId: teamId, matches: matches, existing: existing)
            if !candidates.isEmpty {
                let verdict: DuplicateVerdict
                do {
                    verdict = try await duplicates.judge(DuplicateQuestion(title: title, description: description, candidates: candidates))
                } catch {
                    print("[\(workspace)] Could not compare the proposed issue \"\(title)\" with \(candidates.count) candidate(s); listing them all for review: \(error)")
                    verdict = .possible(keys: candidates.map(\.key))
                }
                switch verdict {
                case .distinct:
                    break
                case .possible(let keys):
                    possibleDuplicates = candidates.filter { keys.contains($0.key) }.map(\.possible)
                case .duplicate(let key, let added):
                    guard let candidate = candidates.first(where: { $0.key == key }) else { break }
                    switch try await repeating(draft, candidate: candidate, added: added) {
                    case .screening(let screening): return screening
                    case .draft(let replacement): draft = replacement
                    }
                }
            }
        }

        if let repeated = Self.repeated(draft, in: existing) { return repeated }

        var trust = autonomy.level(for: draft.payload.kind)
        guard trust != .never else {
            return .skip(reason: "\(draft.payload.kind.rawValue) proposals are set to never")
        }
        // Without an issue to comment on, there is nowhere in Linear to ask.
        if trust == .review, case .postProjectUpdate(_, nil) = draft.payload {
            return .skip(reason: "a project update proposal needs the project's overview issue to be proposed on")
        }
        // The owner decides whether it repeats them.
        if !possibleDuplicates.isEmpty { trust = .review }
        var proposal = Proposal(draft, trust: trust, now: now)
        if !possibleDuplicates.isEmpty { proposal.possibleDuplicates = possibleDuplicates }
        return .store(proposal, applyNow: trust == .auto)
    }

    private enum Repeat {
        case screening(Screening)
        /// Screen this draft in place of the new issue.
        case draft(ProposalDraft)
    }

    /// What becomes of the new issue in `draft`, the same work as `candidate`,
    /// to which it adds `added`.
    private func repeating(_ draft: ProposalDraft, candidate: DuplicateCandidate, added: String) async throws -> Repeat {
        guard case .createIssue(_, _, let title, _, let relatedIssueId) = draft.payload else { return .draft(draft) }
        let section = IssueMerge.section(title: title, added: added)
        switch candidate {
        case .proposal(let earlier) where earlier.status == .rejected:
            return .screening(.skip(reason: "It is the same work as \"\(candidate.title)\", which was rejected before"))
        case .proposal(var earlier):
            guard !added.isEmpty,
                  case .createIssue(let teamId, let projectId, let earlierTitle, let description, let related) = earlier.payload
            else { return .screening(.skip(reason: "It is the same work as \"\(candidate.title)\", which is pending already")) }
            earlier.payload = .createIssue(
                teamId: teamId, projectId: projectId, title: earlierTitle,
                description: IssueMerge.appending(section, to: description), relatedIssueId: related)
            return .screening(.merge(earlier))
        case .issue(let match):
            if !added.isEmpty {
                let issue = try await linear.editableIssue(id: match.id)
                if !issue.handsOff {
                    return .draft(ProposalDraft(
                        payload: IssueMerge.edit(issue, adding: section),
                        target: .issue(issue.id, name: issue.identifier),
                        reason: "\(match.identifier) is the same work as the proposed issue \"\(title)\", which adds to it. \(draft.reason)",
                        source: draft.source,
                        targetUpdatedAt: issue.updatedAt
                    ))
                }
            }
            guard let relatedIssueId, relatedIssueId != match.id else {
                return .screening(.skip(reason: "\(match.identifier) is already open: \(match.title)"))
            }
            return .draft(ProposalDraft(
                payload: .addRelation(relatedIssueId: match.id, type: "related"),
                target: .issue(relatedIssueId),
                reason: "\(match.identifier) already covers the proposed issue \"\(title)\". \(draft.reason)",
                source: draft.source
            ))
        }
    }

    /// A skip when the same change is pending or was rejected.
    private static func repeated(_ draft: ProposalDraft, in existing: [Proposal]) -> Screening? {
        let sameness = Proposal.sameness(draft.payload, draft.target)
        guard let earlier = existing.first(where: { $0.sameness == sameness && [.pending, .rejected].contains($0.status) })
        else { return nil }
        return .skip(reason: earlier.status == .rejected
            ? "The same \(draft.payload.kind.rawValue) was rejected before"
            : "The same \(draft.payload.kind.rawValue) is pending already")
    }

    /// Writes the proposal to Linear and returns it with its new status:
    /// applied; rejected, when its issue is hands off; or pending, sent back
    /// for review when its target changed since it was proposed, or with the
    /// error when the write failed. Each applied change goes in the audit log.
    ///
    /// A proposal sent back for review takes the target's `updatedAt` as it
    /// is now, so that approving it again applies it to the target as the
    /// owner saw it, unless it changes once more.
    func apply(_ proposal: Proposal, now: Date = Date()) async -> Proposal {
        var proposal = proposal
        proposal.lastError = nil
        do {
            switch try await write(proposal) {
            case .applied(let response):
                proposal.status = .applied
                proposal.decidedAt = now
                proposal.reviewNote = nil
                do {
                    try audit.append(AuditEntry(time: now, workspace: workspace, proposal: proposal, response: response))
                } catch {
                    print("[\(workspace)] Could not write the audit log for proposal \(proposal.id): \(error)")
                }
            case .handsOff(let identifier):
                proposal.status = .rejected
                proposal.decidedAt = now
                proposal.rejectionReason = "\(identifier) has the label \"\(Self.handsOffLabel)\""
            case .changed(let note, let updatedAt):
                proposal.trust = .review
                proposal.reviewNote = note
                proposal.targetUpdatedAt = updatedAt
            }
        } catch {
            proposal.lastError = "\(error)"
        }
        return proposal
    }

    private enum Outcome {
        case applied(JSONValue)
        case handsOff(String)
        /// The target changed in Linear; `updatedAt` is its time now.
        case changed(String, updatedAt: Date)
    }

    private func write(_ proposal: Proposal) async throws -> Outcome {
        let target = proposal.target
        switch proposal.payload {
        case .createIssue(let teamId, let projectId, let title, let description, _):
            // One proposed in Linear exists already: accepting it is the change.
            if let post = proposal.post, post.isIssue {
                let labelId = try await linear.labelId(named: Self.proposedLabel, teamId: teamId)
                return .applied(try await linear.removeLabel(issueId: post.issueId, labelId: labelId))
            }
            let labelId = try await linear.labelId(named: Self.label, teamId: teamId)
            let body = [description, proposal.source.line]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
            return .applied(try await linear.createIssue(
                teamId: teamId, projectId: projectId, title: title, description: body, labelIds: [labelId], stateId: nil
            ).response)

        case .editIssue(let oldText, let newText):
            let issue = try await issue(target, for: proposal)
            if let refusal = refusal(of: proposal, on: issue) { return refusal }
            // Without the time it was proposed at, the text it was proposed
            // against tells whether the issue changed.
            let current = issue.createdBySuperlinear ? issue.description : ManagedBlock.contents(of: issue.description) ?? ""
            if proposal.targetUpdatedAt == nil, current != oldText {
                return .changed(changedNote(target, name: issue.identifier), updatedAt: issue.updatedAt)
            }
            let description = issue.createdBySuperlinear ? newText : ManagedBlock.replacing(in: issue.description, with: newText)
            return .applied(try await linear.updateIssueDescription(id: issue.id, description: description))

        case .closeIssue:
            let issue = try await issue(target, for: proposal)
            if let refusal = refusal(of: proposal, on: issue) { return refusal }
            return .applied(try await linear.closeIssue(id: issue.id))

        case .promoteIssue:
            let issue = try await issue(target, for: proposal)
            if let refusal = refusal(of: proposal, on: issue) { return refusal }
            guard issue.stateType == .backlog else {
                return .changed("\(issue.identifier) is no longer in the backlog", updatedAt: issue.updatedAt)
            }
            return .applied(try await linear.promoteIssue(id: issue.id))

        case .addRelation(let relatedIssueId, let type):
            let issue = try await issue(target, for: proposal)
            if issue.handsOff { return .handsOff(issue.identifier) }
            return .applied(try await linear.createRelation(issueId: issue.id, relatedIssueId: relatedIssueId, type: type))

        case .changeSpec(let oldText, let newText):
            guard [.project, .document].contains(target.kind) else {
                throw ProposalError.unsupportedTarget(proposal.kind, target.kind)
            }
            let spec = try await linear.spec(of: target)
            let changed = if let proposed = proposal.targetUpdatedAt {
                spec.updatedAt > proposed.addingTimeInterval(Self.updatedAtTolerance)
            } else {
                spec.content != oldText
            }
            if changed { return .changed(changedNote(target), updatedAt: spec.updatedAt) }
            return .applied(try await linear.updateSpec(of: target, content: newText))

        case .postProjectUpdate(let body, _):
            guard case .project(let projectId, _) = target else {
                throw ProposalError.unsupportedTarget(proposal.kind, target.kind)
            }
            return .applied(try await linear.postProjectUpdate(projectId: projectId, body: body + "\n\n" + proposal.source.line))
        }
    }

    private func issue(_ target: ProposalTarget, for proposal: Proposal) async throws -> EditableIssue {
        guard case .issue(let id, _) = target else { throw ProposalError.unsupportedTarget(proposal.kind, target.kind) }
        return try await linear.editableIssue(id: id)
    }

    /// Why a change to `issue` must not go ahead now, if it must not: the
    /// issue is hands off, or it changed after the proposal was made.
    private func refusal(of proposal: Proposal, on issue: EditableIssue) -> Outcome? {
        if issue.handsOff { return .handsOff(issue.identifier) }
        if let proposed = proposal.targetUpdatedAt,
           issue.updatedAt > proposed.addingTimeInterval(Self.updatedAtTolerance) {
            return .changed(changedNote(proposal.target, name: issue.identifier), updatedAt: issue.updatedAt)
        }
        return nil
    }

    private func changedNote(_ target: ProposalTarget, name: String? = nil) -> String {
        "\(name ?? target.name ?? target.rawID) changed in Linear after this was proposed"
    }
}
