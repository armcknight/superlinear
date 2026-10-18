import Foundation

/// How a proposal reads in Linear: the issue or comment that asks the owner,
/// and the comment once it is answered.
enum ProposalForm {
    /// The reactions that answer a proposal's comment, as Linear names them,
    /// once `normalized`.
    static let approveEmoji: Set<String> = ["👍", "+1", "thumbsup", "thumbs_up"]
    static let rejectEmoji: Set<String> = ["👎", "-1", "thumbsdown", "thumbs_down"]

    /// A time as the comments give it, such as `2026-10-17T20:31:00Z`.
    static func time(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// An emoji as Linear may name it — `:+1:`, `+1::skin-tone-3`, `👍🏽` —
    /// reduced to the name the sets above hold.
    static func normalized(emoji: String) -> String {
        var name = emoji.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        if let tone = name.range(of: "::") { name = String(name[..<tone.lowerBound]) }
        name.unicodeScalars.removeAll { (0x1F3FB...0x1F3FF).contains($0.value) || $0.value == 0xFE0F }
        return name
    }

    /// What the proposal would do, as a clause after "superlinear proposes
    /// to". `related` names the other issue of a relation.
    static func action(_ proposal: Proposal, related: String?) -> String {
        switch proposal.payload {
        case .createIssue(_, _, let title, _, _): "create the issue \"\(title)\""
        case .editIssue: "update this issue's description"
        case .closeIssue: "cancel this issue"
        case .addRelation(let relatedIssueId, let type): "mark this issue as \(type) \(related ?? relatedIssueId.rawValue)"
        case .promoteIssue: "move this issue to Todo"
        case .changeSpec: "change \(specName(proposal.target))"
        case .postProjectUpdate: "post this project update"
        }
    }

    static func specName(_ target: ProposalTarget) -> String {
        switch target {
        case .document: "the spec document"
        case .project(_, let name): "the description of the project \(name ?? target.rawID)"
        case .issue, .team: target.name ?? target.rawID
        }
    }

    /// The first line of a proposal's comment: what it proposes, or what
    /// became of it, with the time. A `superseded` comment was asked again
    /// in a newer one.
    static func headline(_ proposal: Proposal, related: String?, now: Date, superseded: Bool) -> String {
        let action = action(proposal, related: related)
        let time = time(now)
        if superseded { return "**Superseded \(time).** superlinear proposed to \(action)." }
        switch proposal.status {
        case .pending where proposal.reviewNote != nil: return "**superlinear proposes again** to \(action)."
        case .pending: return "**superlinear proposes** to \(action)."
        case .applied: return "**Applied \(time).** superlinear proposed to \(action)."
        case .rejected: return "**Rejected \(time).** superlinear proposed to \(action)."
        case .expired: return "**Expired \(time).** superlinear proposed to \(action)."
        }
    }

    /// The comment on a target issue, the first line being `headline`. Once
    /// the proposal is decided, the line that asks for a reaction is gone.
    static func commentBody(_ proposal: Proposal, related: String?, now: Date, superseded: Bool) -> String {
        var lines = [headline(proposal, related: related, now: now, superseded: superseded), ""]
        if let note = proposal.reviewNote { lines += ["Note: \(note)", ""] }
        lines += ["Reason: \(proposal.reason)", proposal.source.line]
        if let diff = diff(proposal.payload) { lines += [""] + diff }
        if proposal.status == .pending, !superseded {
            lines += ["", "React with 👍 to apply it, or 👎 to reject it. Proposal \(proposal.id.rawValue.prefix(8))."]
        }
        return lines.joined(separator: "\n")
    }

    /// The change as a diff block, for an edit or a spec change.
    static func diff(_ payload: ProposalPayload) -> [String]? {
        switch payload {
        case .editIssue(let old, let new), .changeSpec(let old, let new):
            ["```diff"] + LineDiff.lines(from: old, to: new).map { $0.hasPrefix("  ") ? String($0.dropFirst(2)) : $0 } + ["```"]
        default:
            nil
        }
    }

    /// The title of the issue that proposes a new issue or a spec change.
    static func issueTitle(_ proposal: Proposal) -> String {
        switch proposal.payload {
        case .createIssue(_, _, let title, _, _): title
        case .changeSpec: "Spec change: \(specName(proposal.target))"
        default: "superlinear proposes to \(action(proposal, related: nil))"
        }
    }

    /// The description of the issue that proposes a new issue or a spec
    /// change. `specLink` is where the spec lives, when known.
    static func issueDescription(_ proposal: Proposal, specLink: String?) -> String {
        switch proposal.payload {
        case .createIssue(_, _, _, let description, _):
            return [description, "Proposed by superlinear: \(proposal.reason)", proposal.source.line]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
        default:
            let what = specLink.map { "[\(specName(proposal.target))](\($0))" } ?? specName(proposal.target)
            var lines = [
                "superlinear proposes this change to \(what). Accept this issue to apply it, or decline it to reject it.", "",
                "Reason: \(proposal.reason)", proposal.source.line,
            ]
            if let diff = diff(proposal.payload) { lines += [""] + diff }
            return lines.joined(separator: "\n")
        }
    }

    /// The comment on a proposed issue that lists the open issues and
    /// proposals that may be the same work.
    static func possibleDuplicatesComment(_ duplicates: [PossibleDuplicate]) -> String {
        (["**Possible duplicates.** superlinear found these, which may be the same work as this issue:", ""]
            + duplicates.map(\.line)
            + ["", "If this issue repeats one of them, mark it a duplicate of that issue in Linear: superlinear then rejects this proposal, "
                + "and proposes to add what this issue says to that one. Otherwise accept or decline it as usual."])
            .joined(separator: "\n")
    }

    /// The note left on a proposed issue that expired.
    static func expiryNote(days: Int, now: Date) -> String {
        "**Expired \(time(now)).** superlinear proposed this issue, and canceled it after \(days) days without an answer."
    }

    /// The note left on a proposed issue sent back for review.
    static func reviewAgainNote(_ note: String, now: Date) -> String {
        "**Not applied \(time(now)).** \(note). Accept this issue again to apply the change as it is."
    }
}

/// The owner's answer to a proposal in Linear, read at a poll.
enum ProposalAnswer: Equatable {
    case approve
    case reject(reason: String)
    case none

    /// The answer to `proposal`, from the issue it waits on as Linear has it
    /// now, or nil when Linear no longer has the issue. Only the reactions of
    /// `viewerId`, the API key's user, count.
    static func read(_ proposal: Proposal, snapshot: ProposalIssueSnapshot?, viewerId: LinearUser.ID) -> ProposalAnswer {
        guard let post = proposal.post else { return .none }
        guard let snapshot else {
            return .reject(reason: post.isIssue ? "the proposed issue is no longer in Linear" : "its issue is no longer in Linear")
        }
        switch post.form {
        case .triageIssue:
            switch snapshot.stateType {
            case .triage, .unknown: return .none
            case .canceled: return .reject(reason: "declined in Linear")
            case .duplicate: return .reject(reason: duplicateReason(snapshot))
            default: return .approve
            }
        case .backlogIssue:
            if snapshot.stateType == .canceled { return .reject(reason: "canceled in Linear") }
            if snapshot.stateType == .duplicate { return .reject(reason: duplicateReason(snapshot)) }
            if snapshot.stateType == .unknown { return .none }
            let labeled = snapshot.labels.contains { $0.caseInsensitiveCompare(ProposalEngine.proposedLabel) == .orderedSame }
            return snapshot.stateType != .backlog || !labeled ? .approve : .none
        case .comment:
            guard let comment = snapshot.comments.first(where: { $0.id == post.commentId }) else {
                return .reject(reason: "its comment was removed in Linear")
            }
            let mine = Set(comment.reactions.filter { $0.userId == viewerId }.map { ProposalForm.normalized(emoji: $0.emoji) })
            if !mine.isDisjoint(with: ProposalForm.rejectEmoji) { return .reject(reason: "👎 in Linear") }
            if !mine.isDisjoint(with: ProposalForm.approveEmoji) { return .approve }
            return .none
        }
    }

    private static func duplicateReason(_ snapshot: ProposalIssueSnapshot) -> String {
        snapshot.duplicateOf.map { "marked a duplicate of \($0.identifier) in Linear" } ?? "marked a duplicate in Linear"
    }
}

/// Puts proposals in Linear for the owner to answer, and marks them answered.
struct ProposalPoster: Sendable {
    let linear: any LinearWriting
    /// The team for a proposal with no team of its own, such as a spec
    /// change: the workspace's first configured team, or Linear's first.
    let specTeamId: @Sendable () async throws -> LinearTeam.ID
    /// The spec document, and its URL, when the workspace has one.
    let specDocumentId: LinearDocument.ID?
    let specDocumentURL: String?
    /// Days a proposal waits in Linear before it expires.
    let expiryDays: Int

    /// What posting came to: the proposal with its post, or rejected when its
    /// issue is hands off, and problems met on the way that did not stop it.
    struct Posted: Sendable, Equatable {
        var proposal: Proposal
        var warnings: [String] = []
    }

    /// Puts `proposal` in Linear: a new issue or a spec change as an issue
    /// in Triage, or Backlog when the team has Triage off and it cannot be
    /// turned on; anything else as a comment on its issue.
    func post(_ proposal: Proposal, now: Date) async throws -> Posted {
        switch proposal.payload {
        case .createIssue(let teamId, let projectId, let title, _, _):
            return try await postIssue(
                proposal, teamId: teamId, projectId: projectId, title: title,
                description: ProposalForm.issueDescription(proposal, specLink: nil), labels: [ProposalEngine.label, ProposalEngine.proposedLabel], now: now)
        case .changeSpec:
            var link: String?
            if case .document(let id, _) = proposal.target, id == specDocumentId { link = specDocumentURL }
            return try await postIssue(
                proposal, teamId: try await specTeamId(), projectId: nil, title: ProposalForm.issueTitle(proposal),
                description: ProposalForm.issueDescription(proposal, specLink: link),
                labels: [ProposalEngine.label, ProposalEngine.proposedLabel, ProposalEngine.specLabel], now: now)
        case .postProjectUpdate(_, let overviewIssueId):
            guard let overviewIssueId else { throw ProposalError.unsupportedTarget(.postProjectUpdate, proposal.target.kind) }
            return try await postComment(proposal, issueId: overviewIssueId, now: now)
        case .editIssue, .closeIssue, .addRelation, .promoteIssue:
            guard case .issue(let issueId, _) = proposal.target else {
                throw ProposalError.unsupportedTarget(proposal.kind, proposal.target.kind)
            }
            return try await postComment(proposal, issueId: issueId, now: now)
        }
    }

    private func postIssue(
        _ proposal: Proposal, teamId: LinearTeam.ID, projectId: LinearProject.ID?, title: String, description: String,
        labels: [String], now: Date
    ) async throws -> Posted {
        var proposal = proposal
        var warnings: [String] = []
        var states = try await linear.teamStates(id: teamId)
        if !states.triageEnabled {
            do {
                try await linear.enableTriage(teamId: teamId)
                states = try await linear.teamStates(id: teamId)
            } catch {
                warnings.append("Could not turn on Triage for team \(teamId): \(error). Proposed issues go to Backlog there instead")
            }
        }
        let triage = states.triageEnabled ? states.first(.triage) : nil
        let stateId = triage?.id ?? states.first(.backlog)?.id
        var labelIds: [LinearLabel.ID] = []
        for name in labels { labelIds.append(try await linear.labelId(named: name, teamId: teamId)) }
        let created = try await linear.createIssue(
            teamId: teamId, projectId: projectId, title: title, description: description, labelIds: labelIds, stateId: stateId)
        proposal.post = ProposalPost(
            form: triage == nil ? .backlogIssue : .triageIssue, issueId: created.id, issueIdentifier: created.identifier,
            url: created.url, postedAt: now)
        // The issue is there: a failure here must not post it again.
        if let duplicates = proposal.possibleDuplicates, !duplicates.isEmpty {
            do {
                _ = try await linear.createComment(issueId: created.id, body: ProposalForm.possibleDuplicatesComment(duplicates))
            } catch {
                warnings.append("Could not list the possible duplicates on \(created.identifier): \(error)")
            }
        }
        return Posted(proposal: proposal, warnings: warnings)
    }

    private func postComment(_ proposal: Proposal, issueId: LinearIssue.ID, now: Date) async throws -> Posted {
        var proposal = proposal
        let issue = try await linear.editableIssue(id: issueId)
        if issue.handsOff {
            proposal.status = .rejected
            proposal.decidedAt = now
            proposal.rejectionReason = "\(issue.identifier) has the label \"\(ProposalEngine.handsOffLabel)\""
            return Posted(proposal: proposal)
        }
        let related = await relatedName(proposal)
        let created = try await linear.createComment(
            issueId: issueId, body: ProposalForm.commentBody(proposal, related: related, now: now, superseded: false))
        let labelId = try await linear.labelId(named: ProposalEngine.proposedLabel, teamId: issue.teamId)
        _ = try await linear.addLabel(issueId: issueId, labelId: labelId)
        proposal.post = ProposalPost(
            form: .comment, issueId: issueId, issueIdentifier: issue.identifier, commentId: created.id, url: created.url, postedAt: now)
        return Posted(proposal: proposal)
    }

    /// The identifier of a relation's other issue, when Linear has it.
    private func relatedName(_ proposal: Proposal) async -> String? {
        guard case .addRelation(let relatedIssueId, _) = proposal.payload else { return nil }
        return try? await linear.editableIssue(id: relatedIssueId).identifier
    }

    /// Marks a proposal the owner answered, or that expired, in Linear: a
    /// comment's first line says what became of it; an applied spec change
    /// completes its issue; an expired proposed issue is canceled with a
    /// note. One sent back for review, pending with a note, is asked again:
    /// a new comment, or the proposed issue back in Triage. The proposed
    /// label comes off the issue unless `othersPending` on it.
    func settle(_ proposal: Proposal, othersPending: Bool, now: Date) async throws -> Proposal {
        guard let post = proposal.post else { return proposal }
        var proposal = proposal
        switch post.form {
        case .comment:
            guard let commentId = post.commentId else { return proposal }
            let related = await relatedName(proposal)
            if proposal.status == .pending {
                // Superseded by the comment that asks again.
                _ = try await linear.updateComment(
                    id: commentId, body: ProposalForm.commentBody(proposal, related: related, now: now, superseded: true))
                let created = try await linear.createComment(
                    issueId: post.issueId, body: ProposalForm.commentBody(proposal, related: related, now: now, superseded: false))
                proposal.post = ProposalPost(
                    form: .comment, issueId: post.issueId, issueIdentifier: post.issueIdentifier, commentId: created.id,
                    url: created.url, postedAt: now)
                return proposal
            }
            _ = try await linear.updateComment(id: commentId, body: ProposalForm.commentBody(proposal, related: related, now: now, superseded: false))
            if !othersPending { try await removeProposedLabel(from: post.issueId) }
        case .triageIssue, .backlogIssue:
            switch proposal.status {
            case .pending:
                guard let note = proposal.reviewNote else { return proposal }
                _ = try await linear.createComment(issueId: post.issueId, body: ProposalForm.reviewAgainNote(note, now: now))
                _ = try await linear.moveIssue(id: post.issueId, toFirst: post.form == .triageIssue ? .triage : .backlog)
                proposal.post?.postedAt = now
            case .applied:
                if proposal.kind != .createIssue {
                    _ = try await linear.completeIssue(id: post.issueId)
                    try await removeProposedLabel(from: post.issueId)
                }
            case .rejected:
                try await removeProposedLabel(from: post.issueId)
            case .expired:
                _ = try await linear.createComment(issueId: post.issueId, body: ProposalForm.expiryNote(days: expiryDays, now: now))
                _ = try await linear.closeIssue(id: post.issueId)
                try await removeProposedLabel(from: post.issueId)
            }
        }
        return proposal
    }

    private func removeProposedLabel(from issueId: LinearIssue.ID) async throws {
        let issue = try await linear.editableIssue(id: issueId)
        guard issue.labels.contains(where: { $0.caseInsensitiveCompare(ProposalEngine.proposedLabel) == .orderedSame }) else { return }
        let labelId = try await linear.labelId(named: ProposalEngine.proposedLabel, teamId: issue.teamId)
        _ = try await linear.removeLabel(issueId: issueId, labelId: labelId)
    }
}
