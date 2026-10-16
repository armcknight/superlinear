import Foundation

/// An issue as an edit needs it: its text, labels and when it last changed.
struct EditableIssue: Sendable, Equatable {
    var id: String
    var identifier: String
    var description: String
    var updatedAt: Date
    var labels: [String]
    /// One of Linear's workflow state types, such as `backlog`.
    var stateType: String
    var teamId: String

    /// Whether superlinear created it, as its label says.
    var createdBySuperlinear: Bool { labels.contains { $0.caseInsensitiveCompare(ProposalEngine.label) == .orderedSame } }

    var handsOff: Bool { labels.contains { $0.caseInsensitiveCompare(ProposalEngine.handsOffLabel) == .orderedSame } }
}

/// An open issue whose title may match a new one's.
struct IssueMatch: Sendable, Equatable {
    var id: String
    var identifier: String
    var title: String
}

/// A project's description or a document, as a spec change needs it.
struct SpecText: Sendable, Equatable {
    var content: String
    var updatedAt: Date
}

/// The reads and writes in Linear that proposals need. `LinearClient` does
/// them for real; tests stand in for it. Each write returns Linear's response.
protocol LinearWriting: Sendable {
    func editableIssue(id: String) async throws -> EditableIssue
    /// Open issues in the team whose titles look like `title`, as Linear's
    /// search finds them.
    func openIssues(like title: String, teamId: String) async throws -> [IssueMatch]
    /// The ID of the label with this name in the team or the workspace,
    /// created in the team when there is none.
    func labelId(named name: String, teamId: String) async throws -> String
    func createIssue(
        teamId: String, projectId: String?, title: String, description: String, labelIds: [String]
    ) async throws -> JSONValue
    func updateIssueDescription(id: String, description: String) async throws -> JSONValue
    /// Moves the issue to its team's first canceled state.
    func closeIssue(id: String) async throws -> JSONValue
    /// Moves the issue to its team's first unstarted state, such as Todo.
    func promoteIssue(id: String) async throws -> JSONValue
    func createRelation(issueId: String, relatedIssueId: String, type: String) async throws -> JSONValue
    func spec(of target: ProposalTarget) async throws -> SpecText
    func updateSpec(of target: ProposalTarget, content: String) async throws -> JSONValue
    func postProjectUpdate(projectId: String, body: String) async throws -> JSONValue
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
    /// The state file keeps dates to the second, and Linear to the
    /// millisecond, so an `updatedAt` within this much of the one proposed
    /// counts as the same.
    static let updatedAtTolerance: TimeInterval = 1

    let workspace: String
    let autonomy: Autonomy
    let linear: any LinearWriting
    let audit: AuditLog

    enum Screening: Equatable {
        /// Store this proposal, and apply it at once when `applyNow`.
        case store(Proposal, applyNow: Bool)
        case skip(reason: String)
    }

    /// What to do with `draft`, given the workspace's proposals so far. A new
    /// issue like an open one becomes a relation between that one and the
    /// issue the new one follows from, or nothing when it follows from none.
    func screen(_ draft: ProposalDraft, existing: [Proposal], now: Date = Date()) async throws -> Screening {
        var draft = draft
        if case .createIssue(let teamId, _, let title, _, let relatedIssueId) = draft.payload {
            let matches = try await linear.openIssues(like: title, teamId: teamId)
            if let match = matches.first(where: { TitleMatch.isClose($0.title, title) }) {
                guard let relatedIssueId, relatedIssueId != match.id else {
                    return .skip(reason: "\(match.identifier) is already open: \(match.title)")
                }
                draft = ProposalDraft(
                    payload: .addRelation(relatedIssueId: match.id, type: "related"),
                    target: ProposalTarget(kind: .issue, id: relatedIssueId),
                    reason: "\(match.identifier) already covers the proposed issue \"\(title)\". \(draft.reason)",
                    source: draft.source
                )
            }
        }

        let sameness = Proposal.sameness(draft.payload, draft.target)
        if let earlier = existing.first(where: { $0.sameness == sameness && [.pending, .rejected].contains($0.status) }) {
            return .skip(reason: earlier.status == .rejected
                ? "The same \(draft.payload.kind.rawValue) was rejected before"
                : "The same \(draft.payload.kind.rawValue) is pending already")
        }

        let trust = autonomy.level(for: draft.payload.kind)
        guard trust != .never else {
            return .skip(reason: "\(draft.payload.kind.rawValue) proposals are set to never")
        }
        return .store(Proposal(draft, trust: trust, now: now), applyNow: trust == .auto)
    }

    /// Writes the proposal to Linear and returns it with its new status:
    /// applied; rejected, when its issue is hands off; or pending, sent back
    /// for review when its target changed since it was proposed, or with the
    /// error when the write failed. Each applied change goes in the audit log.
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
            case .changed(let note):
                proposal.trust = .standup
                proposal.reviewNote = note
            }
        } catch {
            proposal.lastError = "\(error)"
        }
        return proposal
    }

    private enum Outcome {
        case applied(JSONValue)
        case handsOff(String)
        case changed(String)
    }

    private func write(_ proposal: Proposal) async throws -> Outcome {
        let target = proposal.target
        switch proposal.payload {
        case .createIssue(let teamId, let projectId, let title, let description, _):
            let labelId = try await linear.labelId(named: Self.label, teamId: teamId)
            let body = [description, proposal.source.line]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
            return .applied(try await linear.createIssue(
                teamId: teamId, projectId: projectId, title: title, description: body, labelIds: [labelId]
            ))

        case .editIssue(let oldText, let newText):
            let issue = try await issue(target, for: proposal)
            if let refusal = refusal(of: proposal, on: issue) { return refusal }
            // Without the time it was proposed at, the text it was proposed
            // against tells whether the issue changed.
            let current = issue.createdBySuperlinear ? issue.description : ManagedBlock.contents(of: issue.description) ?? ""
            if proposal.targetUpdatedAt == nil, current != oldText {
                return .changed(changedNote(target, name: issue.identifier))
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
            guard issue.stateType == "backlog" else {
                return .changed("\(issue.identifier) is no longer in the backlog")
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
            if changed { return .changed(changedNote(target)) }
            return .applied(try await linear.updateSpec(of: target, content: newText))

        case .postProjectUpdate(let body):
            guard target.kind == .project else { throw ProposalError.unsupportedTarget(proposal.kind, target.kind) }
            return .applied(try await linear.postProjectUpdate(projectId: target.id, body: body + "\n\n" + proposal.source.line))
        }
    }

    private func issue(_ target: ProposalTarget, for proposal: Proposal) async throws -> EditableIssue {
        guard target.kind == .issue else { throw ProposalError.unsupportedTarget(proposal.kind, target.kind) }
        return try await linear.editableIssue(id: target.id)
    }

    /// Why a change to `issue` must not go ahead now, if it must not: the
    /// issue is hands off, or it changed after the proposal was made.
    private func refusal(of proposal: Proposal, on issue: EditableIssue) -> Outcome? {
        if issue.handsOff { return .handsOff(issue.identifier) }
        if let proposed = proposal.targetUpdatedAt,
           issue.updatedAt > proposed.addingTimeInterval(Self.updatedAtTolerance) {
            return .changed(changedNote(proposal.target, name: issue.identifier))
        }
        return nil
    }

    private func changedNote(_ target: ProposalTarget, name: String? = nil) -> String {
        "\(name ?? target.name ?? target.id) changed in Linear after this was proposed"
    }
}
