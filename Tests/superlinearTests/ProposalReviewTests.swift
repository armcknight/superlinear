import Foundation
import Testing
@testable import superlinear

/// Linear as proposals under review see it, kept in memory: issues with
/// their states, labels and comments, the comments' reactions, and a team
/// whose Triage may be on or off. Every write is recorded.
private actor FakeLinear: LinearWriting {
    var issues: [LinearIssue.ID: EditableIssue] = [:]
    var urls: [LinearIssue.ID: String] = [:]
    var comments: [LinearIssue.ID: [ProposalIssueSnapshot.Comment]] = [:]
    var commentBodies: [LinearComment.ID: String] = [:]
    var labelIds: [String: LinearLabel.ID] = [:]
    var labelNames: [LinearLabel.ID: String] = [:]
    var specs: [String: SpecText] = [:]
    var triageEnabled = true
    var canEnableTriage = true
    var viewer: LinearUser.ID = "owner"
    var writes: [String] = []
    var duplicateOf: [LinearIssue.ID: ProposalIssueSnapshot.Related] = [:]
    private var created = 0

    init(issues: [EditableIssue] = [], triageEnabled: Bool = true, canEnableTriage: Bool = true) {
        self.issues = Dictionary(uniqueKeysWithValues: issues.map { ($0.id, $0) })
        self.triageEnabled = triageEnabled
        self.canEnableTriage = canEnableTriage
    }

    // MARK: What the owner does

    func react(_ emoji: String, by user: LinearUser.ID, on commentId: LinearComment.ID) {
        for (issueId, list) in comments {
            guard let index = list.firstIndex(where: { $0.id == commentId }) else { continue }
            comments[issueId]?[index].reactions.append(.init(emoji: emoji, userId: user))
        }
    }

    func move(_ id: LinearIssue.ID, to type: LinearStateType) {
        issues[id]?.stateType = type
    }

    func markDuplicate(_ id: LinearIssue.ID, of original: ProposalIssueSnapshot.Related) {
        issues[id]?.stateType = .duplicate
        duplicateOf[id] = original
    }

    func unlabel(_ id: LinearIssue.ID, _ name: String) {
        issues[id]?.labels.removeAll { $0 == name }
    }

    func delete(_ id: LinearIssue.ID) {
        issues[id] = nil
        comments[id] = nil
    }

    func setSpec(_ spec: SpecText, id: String) { specs[id] = spec }

    // MARK: LinearWriting

    private func written(_ description: String) -> JSONValue {
        writes.append(description)
        return .object(["write": .string(description)])
    }

    func viewerId() async throws -> LinearUser.ID { viewer }

    func editableIssue(id: LinearIssue.ID) async throws -> EditableIssue {
        guard let issue = issues[id] else { throw LinearClientError.apiError(["Entity not found"]) }
        return issue
    }

    func openIssues(like title: String, teamId: LinearTeam.ID) async throws -> [IssueMatch] { [] }

    func labelId(named name: String, teamId: LinearTeam.ID) async throws -> LinearLabel.ID {
        if let id = labelIds[name] { return id }
        let id = LinearLabel.ID(rawValue: "label-\(labelIds.count)")
        labelIds[name] = id
        labelNames[id] = name
        return id
    }

    func teamStates(id: LinearTeam.ID) async throws -> TeamStates {
        TeamStates(triageEnabled: triageEnabled, states: [
            .init(id: "s-triage", type: .triage, position: 0), .init(id: "s-backlog", type: .backlog, position: 1),
            .init(id: "s-todo", type: .unstarted, position: 2), .init(id: "s-done", type: .completed, position: 3),
            .init(id: "s-canceled", type: .canceled, position: 4),
        ])
    }

    func enableTriage(teamId: LinearTeam.ID) async throws {
        guard canEnableTriage else { throw LinearClientError.apiError(["admin only"]) }
        triageEnabled = true
        writes.append("enable triage")
    }

    func createIssue(
        teamId: LinearTeam.ID, projectId: LinearProject.ID?, title: String, description: String,
        labelIds: [LinearLabel.ID], stateId: LinearState.ID?
    ) async throws -> CreatedIssue {
        created += 1
        let id = LinearIssue.ID(rawValue: "new-\(created)")
        let identifier = "NEW-\(created)"
        let type: LinearStateType = switch stateId {
        case "s-triage": .triage
        case "s-backlog": .backlog
        default: .unstarted
        }
        issues[id] = EditableIssue(
            id: id, identifier: identifier, description: description, updatedAt: Date(), labels: labelIds.compactMap { labelNames[$0] },
            stateType: type, teamId: teamId)
        urls[id] = "https://linear.app/t/issue/\(identifier)"
        let response = written("create \(title) state=\(stateId ?? "default") labels=\(labelIds.compactMap { labelNames[$0] })")
        return CreatedIssue(id: id, identifier: identifier, url: urls[id], response: response)
    }

    func updateIssueDescription(id: LinearIssue.ID, description: String) async throws -> JSONValue {
        issues[id]?.description = description
        return written("edit \(id)")
    }

    func closeIssue(id: LinearIssue.ID) async throws -> JSONValue {
        issues[id]?.stateType = .canceled
        return written("close \(id)")
    }

    func promoteIssue(id: LinearIssue.ID) async throws -> JSONValue {
        issues[id]?.stateType = .unstarted
        return written("promote \(id)")
    }

    func completeIssue(id: LinearIssue.ID) async throws -> Bool {
        issues[id]?.stateType = .completed
        writes.append("complete \(id)")
        return true
    }

    func moveIssue(id: LinearIssue.ID, toFirst type: LinearStateType) async throws -> JSONValue {
        issues[id]?.stateType = type
        return written("move \(id) to \(type.rawValue)")
    }

    func createRelation(issueId: LinearIssue.ID, relatedIssueId: LinearIssue.ID, type: String) async throws -> JSONValue {
        written("relate \(issueId) \(type) \(relatedIssueId)")
    }

    func createComment(issueId: LinearIssue.ID, body: String) async throws -> CreatedComment {
        guard issues[issueId] != nil else { throw LinearClientError.apiError(["Entity not found"]) }
        let id = LinearComment.ID(rawValue: "c\(commentBodies.count + 1)")
        commentBodies[id] = body
        comments[issueId, default: []].append(.init(id: id, reactions: []))
        return CreatedComment(id: id, url: "https://linear.app/t/issue/\(issues[issueId]!.identifier)#comment-\(id)", response: written("comment \(issueId)"))
    }

    func updateComment(id: LinearComment.ID, body: String) async throws -> JSONValue {
        guard commentBodies[id] != nil else { throw LinearClientError.apiError(["Entity not found"]) }
        commentBodies[id] = body
        return written("update \(id)")
    }

    func addLabel(issueId: LinearIssue.ID, labelId: LinearLabel.ID) async throws -> JSONValue {
        guard let name = labelNames[labelId] else { throw LinearClientError.invalidResponse }
        if issues[issueId]?.labels.contains(name) == false { issues[issueId]?.labels.append(name) }
        return written("label \(issueId) \(name)")
    }

    func removeLabel(issueId: LinearIssue.ID, labelId: LinearLabel.ID) async throws -> JSONValue {
        guard let name = labelNames[labelId] else { throw LinearClientError.invalidResponse }
        issues[issueId]?.labels.removeAll { $0 == name }
        return written("unlabel \(issueId) \(name)")
    }

    func proposalIssues(ids: [LinearIssue.ID]) async throws -> [ProposalIssueSnapshot] {
        ids.compactMap { id in
            guard let issue = issues[id] else { return nil }
            return ProposalIssueSnapshot(
                id: id, identifier: issue.identifier, stateType: issue.stateType, labels: issue.labels, comments: comments[id] ?? [],
                duplicateOf: duplicateOf[id])
        }
    }

    func spec(of target: ProposalTarget) async throws -> SpecText {
        guard let spec = specs[target.rawID] else { throw LinearClientError.apiError(["Entity not found"]) }
        return spec
    }

    func updateSpec(of target: ProposalTarget, content: String) async throws -> JSONValue {
        specs[target.rawID]?.content = content
        return written("spec \(target.rawID)")
    }

    func postProjectUpdate(projectId: LinearProject.ID, body: String) async throws -> JSONValue {
        written("project update \(projectId)")
    }
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let proposedAt = now.addingTimeInterval(-3600)
private let source = ProposalSource(kind: .pullRequest, value: "https://github.com/o/r/pull/7")
private let proposedLabel = ProposalEngine.proposedLabel

private func issue(_ id: String, description: String = "", labels: [String] = [], state: LinearStateType = .unstarted) -> EditableIssue {
    EditableIssue(
        id: LinearIssue.ID(rawValue: id), identifier: id.uppercased(), description: description, updatedAt: proposedAt,
        labels: labels, stateType: state, teamId: "team")
}

private func proposal(
    _ payload: ProposalPayload, target: ProposalTarget = .issue("i1", name: "I1"), id: String = "p1",
    reason: String = "because", updatedAt: Date? = proposedAt, trust: TrustLevel = .review
) -> Proposal {
    Proposal(
        ProposalDraft(payload: payload, target: target, reason: reason, source: source, targetUpdatedAt: updatedAt),
        trust: trust, id: Proposal.ID(rawValue: id), now: proposedAt)
}

private func newIssue(_ title: String = "Add retries", id: String = "p1") -> Proposal {
    proposal(
        .createIssue(teamId: "team", projectId: nil, title: title, description: "Do it.", relatedIssueId: nil),
        target: .team("team"), id: id, updatedAt: nil)
}

private let specTarget = ProposalTarget.document("spec", name: "the spec")

private func specChange() -> Proposal {
    proposal(.changeSpec(oldText: "Spec", newText: "Spec v2"), target: specTarget, updatedAt: proposedAt)
}

private func poster(_ linear: FakeLinear) -> ProposalPoster {
    ProposalPoster(
        linear: linear, specTeamId: { "team" }, specDocumentId: "spec",
        specDocumentURL: "https://linear.app/t/document/the-spec-spec", expiryDays: 7)
}

private func engine(_ linear: FakeLinear) -> ProposalEngine {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("superlinear-\(UUID().uuidString)")
    return ProposalEngine(workspace: "w", autonomy: Autonomy(), linear: linear, audit: AuditLog(directory: scratch), duplicates: StubDuplicates())
}

/// The owner's answer to `proposal`, as a poll would read it.
private func answer(_ proposal: Proposal, linear: FakeLinear, viewer: LinearUser.ID = "owner") async throws -> ProposalAnswer {
    let snapshot = try await linear.proposalIssues(ids: [proposal.post!.issueId]).first
    return ProposalAnswer.read(proposal, snapshot: snapshot, viewerId: viewer)
}

@Suite("Proposals in Linear: forms")
struct ProposalFormTests {
    @Test("A new issue is created at once in Triage, labeled superlinear and proposed, with its reason and source")
    func createIssue() async throws {
        let linear = FakeLinear()
        let posted = try await poster(linear).post(newIssue(), now: now)
        #expect(posted.warnings.isEmpty)
        let post = try #require(posted.proposal.post)
        #expect(post.form == .triageIssue)
        #expect(post.postedAt == now)
        #expect(post.url == "https://linear.app/t/issue/NEW-1")
        let created = try #require(await linear.issues[post.issueId])
        #expect(created.stateType == .triage)
        #expect(created.labels == ["superlinear", proposedLabel])
        #expect(created.description == "Do it.\n\nProposed by superlinear: because\n\nSource: https://github.com/o/r/pull/7")
    }

    @Test("A team with Triage off gets it turned on; one that cannot takes proposals in Backlog, with a warning")
    func triageOff() async throws {
        let linear = FakeLinear(triageEnabled: false)
        let posted = try await poster(linear).post(newIssue(), now: now)
        #expect(posted.proposal.post?.form == .triageIssue)
        #expect(await linear.writes.first == "enable triage")

        let locked = FakeLinear(triageEnabled: false, canEnableTriage: false)
        let backlog = try await poster(locked).post(newIssue(), now: now)
        #expect(backlog.proposal.post?.form == .backlogIssue)
        #expect(backlog.warnings.count == 1)
        #expect(backlog.warnings[0].contains("Could not turn on Triage"))
        #expect(await locked.issues[backlog.proposal.post!.issueId]?.stateType == .backlog)
    }

    @Test("An edit, a closure, a relation and a promotion are comments on the issue, which gets the proposed label")
    func comments() async throws {
        let linear = FakeLinear(issues: [issue("i1", description: "Mine"), issue("i2")])
        let payloads: [ProposalPayload] = [
            .editIssue(oldText: "Old plan", newText: "New plan"), .closeIssue,
            .addRelation(relatedIssueId: "i2", type: "blocks"), .promoteIssue,
        ]
        var bodies: [String] = []
        for (index, payload) in payloads.enumerated() {
            let posted = try await poster(linear).post(proposal(payload, id: "p\(index)"), now: now)
            let post = try #require(posted.proposal.post)
            #expect(post.form == .comment)
            #expect(post.issueId == "i1")
            #expect(post.issueIdentifier == "I1")
            #expect(post.url?.hasSuffix("#comment-\(post.commentId!)") == true)
            bodies.append(try #require(await linear.commentBodies[post.commentId!]))
        }
        #expect(bodies[0].hasPrefix("**superlinear proposes** to update this issue's description.\n\nReason: because\nSource: https://github.com/o/r/pull/7\n\n```diff\n- Old plan\n+ New plan\n```"))
        #expect(bodies[0].hasSuffix("React with 👍 to apply it, or 👎 to reject it. Proposal p0."))
        #expect(bodies[1].hasPrefix("**superlinear proposes** to cancel this issue."))
        #expect(bodies[2].hasPrefix("**superlinear proposes** to mark this issue as blocks I2."))
        #expect(bodies[3].hasPrefix("**superlinear proposes** to move this issue to Todo."))
        #expect(await linear.issues["i1"]?.labels == [proposedLabel])
    }

    @Test("A spec change is an issue in Triage, labeled spec, with the diff and a link to the document")
    func specChangeIssue() async throws {
        let linear = FakeLinear()
        let posted = try await poster(linear).post(specChange(), now: now)
        let post = try #require(posted.proposal.post)
        #expect(post.form == .triageIssue)
        let created = try #require(await linear.issues[post.issueId])
        #expect(created.labels == ["superlinear", proposedLabel, ProposalEngine.specLabel])
        #expect(created.description.contains("[the spec document](https://linear.app/t/document/the-spec-spec)"))
        #expect(created.description.contains("```diff\n- Spec\n+ Spec v2\n```"))
        #expect(await linear.writes.last?.hasPrefix("create Spec change: the spec document state=s-triage") == true)
    }

    @Test("A project update is a comment on the project's overview issue, and is not proposed without one")
    func projectUpdate() async throws {
        let linear = FakeLinear(issues: [issue("i1")])
        let update = proposal(.postProjectUpdate(body: "All green.", overviewIssueId: "i1"), target: .project("pr", name: "Planning"))
        let posted = try await poster(linear).post(update, now: now)
        #expect(posted.proposal.post?.form == .comment)
        #expect(await linear.commentBodies["c1"]?.hasPrefix("**superlinear proposes** to post this project update.") == true)

        let orphan = ProposalDraft(
            payload: .postProjectUpdate(body: "All green."), target: .project("pr"), reason: "r", source: source)
        guard case .skip(let reason) = try await engine(linear).screen(orphan, existing: []) else {
            Issue.record("A project update without an overview issue was stored")
            return
        }
        #expect(reason.contains("overview issue"))
    }

    @Test("A proposal on a hands-off issue is rejected instead of posted")
    func handsOff() async throws {
        let linear = FakeLinear(issues: [issue("i1", labels: ["superlinear: hands off"])])
        let posted = try await poster(linear).post(proposal(.closeIssue), now: now)
        #expect(posted.proposal.status == .rejected)
        #expect(posted.proposal.post == nil)
        #expect(await linear.writes.isEmpty)
    }

    @Test("Linear's names for the thumbs normalize, skin tones and colons aside")
    func emoji() {
        for name in ["👍", "👍🏽", "+1", ":+1:", "+1::skin-tone-3", "thumbsup", ":thumbsup:"] {
            #expect(ProposalForm.approveEmoji.contains(ProposalForm.normalized(emoji: name)), "\(name)")
        }
        for name in ["👎", "-1", ":-1:", "thumbsdown"] {
            #expect(ProposalForm.rejectEmoji.contains(ProposalForm.normalized(emoji: name)), "\(name)")
        }
        #expect(!ProposalForm.approveEmoji.contains(ProposalForm.normalized(emoji: "heart")))
    }
}

@Suite("Proposals in Linear: answers")
struct ProposalAnswerTests {
    @Test("Accepting a proposed issue from Triage approves it, and the proposed label comes off")
    func acceptFromTriage() async throws {
        let linear = FakeLinear()
        let posted = try await poster(linear).post(newIssue(), now: now).proposal
        #expect(try await answer(posted, linear: linear) == .none)
        await linear.move(posted.post!.issueId, to: .backlog)
        #expect(try await answer(posted, linear: linear) == .approve)

        let applied = await engine(linear).apply(posted, now: now)
        #expect(applied.status == .applied)
        #expect(await linear.issues[posted.post!.issueId]?.labels == ["superlinear"])
        // Nothing more to do in Linear: the issue is the owner's now.
        let settled = try await poster(linear).settle(applied, othersPending: false, now: now)
        #expect(settled == applied)
        #expect(await linear.writes.filter { $0.hasPrefix("create") }.count == 1)
    }

    @Test("A proposed issue marked a duplicate is rejected")
    func duplicateFromTriage() async throws {
        let linear = FakeLinear()
        let posted = try await poster(linear).post(newIssue(), now: now).proposal
        await linear.move(posted.post!.issueId, to: .duplicate)
        #expect(try await answer(posted, linear: linear) == .reject(reason: "marked a duplicate in Linear"))
    }

    @Test("A proposed issue marked a duplicate of another names it, and its text can be merged into that one")
    func duplicateOfAnother() async throws {
        let original = EditableIssue(
            id: "i9", identifier: "SPL-9", description: "Mine.", updatedAt: now, labels: [], stateType: .backlog, teamId: "team")
        let linear = FakeLinear(issues: [original])
        let posted = try await poster(linear).post(newIssue(), now: now).proposal
        await linear.markDuplicate(posted.post!.issueId, of: .init(id: "i9", identifier: "SPL-9"))
        #expect(try await answer(posted, linear: linear) == .reject(reason: "marked a duplicate of SPL-9 in Linear"))

        let merge = IssueMerge.draft(merging: posted, text: "Do it.", into: original)
        #expect(merge.payload == .editIssue(oldText: "", newText: "### Also from \"Add retries\"\n\nDo it."))
        #expect(merge.target == .issue("i9", name: "SPL-9"))
        #expect(merge.targetUpdatedAt == now)
        #expect(merge.reason.contains("marked a duplicate of SPL-9"))
    }

    @Test("A proposed issue that may repeat others lists them in a comment")
    func possibleDuplicatesListed() async throws {
        let linear = FakeLinear()
        var proposal = newIssue()
        proposal.possibleDuplicates = [
            PossibleDuplicate(name: "SPL-9", title: "Make sync robust", url: "https://l/SPL-9"),
            PossibleDuplicate(name: "proposal 1a2b3c4d", title: "Old idea", note: "rejected proposal"),
        ]
        let posted = try await poster(linear).post(proposal, now: now)
        #expect(posted.warnings.isEmpty)
        let comments = await linear.comments[posted.proposal.post!.issueId] ?? []
        #expect(comments.count == 1)
        let body = try #require(await linear.commentBodies[comments[0].id])
        #expect(body.hasPrefix("**Possible duplicates.**"))
        #expect(body.contains("- [SPL-9](https://l/SPL-9): Make sync robust"))
        #expect(body.contains("- proposal 1a2b3c4d: Old idea (rejected proposal)"))
        #expect(body.contains("mark it a duplicate"))
    }

    @Test("Declining a proposed issue rejects it, so the same issue is not proposed again")
    func declineFromTriage() async throws {
        let linear = FakeLinear()
        let posted = try await poster(linear).post(newIssue(), now: now).proposal
        await linear.move(posted.post!.issueId, to: .canceled)
        #expect(try await answer(posted, linear: linear) == .reject(reason: "declined in Linear"))

        var state = State()
        state.recordProposal(posted, workspace: "w")
        state.rejectProposal(id: posted.id, reason: "declined in Linear", workspace: "w", now: now)
        let again = try await engine(linear).screen(
            ProposalDraft(payload: newIssue().payload, target: .team("team"), reason: "r", source: source),
            existing: state.proposals(workspace: "w"))
        guard case .skip(let reason) = again else {
            Issue.record("A declined issue was proposed again")
            return
        }
        #expect(reason.contains("rejected"))
        // A deleted issue counts as declined too.
        await linear.delete(posted.post!.issueId)
        #expect(try await answer(posted, linear: linear) == .reject(reason: "the proposed issue is no longer in Linear"))
    }

    @Test("In a team without Triage, moving the issue out of Backlog or removing the label approves; canceling rejects")
    func backlogAnswers() async throws {
        let linear = FakeLinear(triageEnabled: false, canEnableTriage: false)
        let posted = try await poster(linear).post(newIssue(), now: now).proposal
        let id = posted.post!.issueId
        #expect(posted.post?.form == .backlogIssue)
        #expect(try await answer(posted, linear: linear) == .none)
        await linear.unlabel(id, proposedLabel)
        #expect(try await answer(posted, linear: linear) == .approve)

        let moved = try await poster(linear).post(newIssue("Another"), now: now).proposal
        await linear.move(moved.post!.issueId, to: .unstarted)
        #expect(try await answer(moved, linear: linear) == .approve)

        let canceled = try await poster(linear).post(newIssue("Third"), now: now).proposal
        await linear.move(canceled.post!.issueId, to: .canceled)
        #expect(try await answer(canceled, linear: linear) == .reject(reason: "canceled in Linear"))
    }

    @Test("A 👍 from the API key's user applies a comment proposal; 👎 rejects it; anyone else's is ignored")
    func reactions() async throws {
        let linear = FakeLinear(issues: [issue("i1", description: "Mine")])
        let posted = try await poster(linear).post(proposal(.closeIssue), now: now).proposal
        let commentId = posted.post!.commentId!
        #expect(try await answer(posted, linear: linear) == .none)

        await linear.react("+1", by: "someone-else", on: commentId)
        #expect(try await answer(posted, linear: linear) == .none)

        await linear.react("+1::skin-tone-2", by: "owner", on: commentId)
        #expect(try await answer(posted, linear: linear) == .approve)
        let applied = await engine(linear).apply(posted, now: now)
        #expect(applied.status == .applied)
        #expect(await linear.issues["i1"]?.stateType == .canceled)

        let settled = try await poster(linear).settle(applied, othersPending: false, now: now)
        #expect(settled == applied)
        let body = try #require(await linear.commentBodies[commentId])
        #expect(body.hasPrefix("**Applied 2027-01-15T08:00:00Z.** superlinear proposed to cancel this issue.\n\nReason: because"))
        #expect(!body.contains("React with"))
        #expect(await linear.issues["i1"]?.labels == [])

        let other = try await poster(linear).post(proposal(.promoteIssue, id: "p2"), now: now).proposal
        await linear.react("👎", by: "owner", on: other.post!.commentId!)
        await linear.react("👍", by: "owner", on: other.post!.commentId!)
        // A thumbs down wins over a thumbs up from the same person.
        #expect(try await answer(other, linear: linear) == .reject(reason: "👎 in Linear"))
        var rejected = other
        rejected.status = .rejected
        rejected.rejectionReason = "👎 in Linear"
        _ = try await poster(linear).settle(rejected, othersPending: true, now: now)
        #expect(await linear.commentBodies[other.post!.commentId!]?.hasPrefix("**Rejected 2027-01-15T08:00:00Z.**") == true)
        // Another proposal still waits on the issue, so the label stays.
        #expect(await linear.issues["i1"]?.labels == [proposedLabel])
        // A comment the owner deleted counts as rejected.
        await linear.delete("i1")
        #expect(try await answer(other, linear: linear) == .reject(reason: "its issue is no longer in Linear"))
    }

    @Test("An issue changed after the proposal is not overwritten; superlinear asks again in a new comment")
    func changedIssue() async throws {
        let linear = FakeLinear(issues: [issue("i1", description: "Mine")])
        let posted = try await poster(linear).post(proposal(.editIssue(oldText: "", newText: "Note")), now: now).proposal
        let first = posted.post!.commentId!
        await linear.react("👍", by: "owner", on: first)
        // The owner edited the issue after the proposal was made.
        let edited = Date(timeIntervalSince1970: 1_800_000_500)
        _ = try await linear.updateIssueDescription(id: "i1", description: "Mine, edited")
        await linear.touch("i1", at: edited)

        #expect(try await answer(posted, linear: linear) == .approve)
        let result = await engine(linear).apply(posted, now: now)
        #expect(result.status == .pending)
        #expect(result.reviewNote == "I1 changed in Linear after this was proposed")
        #expect(result.targetUpdatedAt == edited)
        #expect(await linear.issues["i1"]?.description == "Mine, edited")

        let asked = try await poster(linear).settle(result, othersPending: false, now: now)
        let second = try #require(asked.post?.commentId)
        #expect(second != first)
        #expect(asked.post?.postedAt == now)
        #expect(await linear.commentBodies[first]?.hasPrefix("**Superseded 2027-01-15T08:00:00Z.**") == true)
        let body = try #require(await linear.commentBodies[second])
        #expect(body.hasPrefix("**superlinear proposes again** to update this issue's description.\n\nNote: I1 changed in Linear after this was proposed"))
        #expect(await linear.issues["i1"]?.labels == [proposedLabel])
        // The old reaction does not count; a new one applies it to the issue as it is now.
        #expect(try await answer(asked, linear: linear) == .none)
        await linear.react("👍", by: "owner", on: second)
        #expect(try await answer(asked, linear: linear) == .approve)
        let applied = await engine(linear).apply(asked, now: now)
        #expect(applied.status == .applied)
        #expect(ManagedBlock.contents(of: try #require(await linear.issues["i1"]?.description)) == "Note")
    }

    @Test("Accepting a spec change applies it to the document and completes the issue")
    func specChangeAccepted() async throws {
        let linear = FakeLinear()
        await linear.setSpec(SpecText(content: "Spec", updatedAt: proposedAt), id: "spec")
        let posted = try await poster(linear).post(specChange(), now: now).proposal
        let id = posted.post!.issueId
        await linear.move(id, to: .unstarted)
        #expect(try await answer(posted, linear: linear) == .approve)
        let applied = await engine(linear).apply(posted, now: now)
        #expect(applied.status == .applied)
        #expect(await linear.specs["spec"]?.content == "Spec v2")
        _ = try await poster(linear).settle(applied, othersPending: false, now: now)
        #expect(await linear.issues[id]?.stateType == .completed)
        #expect(await linear.issues[id]?.labels == ["superlinear", ProposalEngine.specLabel])

        // A document that changed since goes back to Triage with a note.
        await linear.setSpec(SpecText(content: "Spec v3", updatedAt: now), id: "spec")
        let stale = try await poster(linear).post(proposal(.changeSpec(oldText: "Spec", newText: "Spec v4"), target: specTarget, id: "p2"), now: now).proposal
        await linear.move(stale.post!.issueId, to: .unstarted)
        let back = await engine(linear).apply(stale, now: now)
        #expect(back.status == .pending)
        let asked = try await poster(linear).settle(back, othersPending: false, now: now)
        #expect(await linear.issues[stale.post!.issueId]?.stateType == .triage)
        #expect(asked.post?.postedAt == now)
        #expect(await linear.commentBodies.values.contains { $0.hasPrefix("**Not applied 2027-01-15T08:00:00Z.** the spec changed in Linear") })
    }

}

private extension FakeLinear {
    func touch(_ id: LinearIssue.ID, at date: Date) {
        issues[id]?.updatedAt = date
    }
}

@Suite("Proposals in Linear: expiry and migration")
struct ProposalExpiryInLinearTests {
    @Test("Expiry counts from when the proposal was put in Linear; a comment says so, a proposed issue is canceled with a note")
    func expiry() async throws {
        let linear = FakeLinear(issues: [issue("i1")])
        let day: TimeInterval = 24 * 60 * 60
        let comment = try await poster(linear).post(proposal(.closeIssue, id: "c"), now: now.addingTimeInterval(-8 * day)).proposal
        let triage = try await poster(linear).post(newIssue(id: "t"), now: now.addingTimeInterval(-8 * day)).proposal
        let fresh = try await poster(linear).post(newIssue("Fresh", id: "f"), now: now.addingTimeInterval(-6 * day)).proposal
        var state = State()
        for proposal in [comment, triage, fresh] { state.recordProposal(proposal, workspace: "w") }

        let expired = state.expireProposals(olderThanDays: 7, workspace: "w", now: now)
        #expect(expired.map(\.id) == [comment.id, triage.id])
        for proposal in expired {
            _ = try await poster(linear).settle(proposal, othersPending: false, now: now)
        }
        #expect(await linear.commentBodies[comment.post!.commentId!]?.hasPrefix("**Expired 2027-01-15T08:00:00Z.** superlinear proposed to cancel this issue.") == true)
        #expect(await linear.issues["i1"]?.labels == [])
        let canceled = try #require(await linear.issues[triage.post!.issueId])
        #expect(canceled.stateType == .canceled)
        #expect(canceled.labels == ["superlinear"])
        #expect(await linear.commentBodies.values.contains { $0.hasPrefix("**Expired 2027-01-15T08:00:00Z.** superlinear proposed this issue, and canceled it after 7 days") })
        #expect(await linear.issues[fresh.post!.issueId]?.stateType == .triage)
    }

    @Test("Pending proposals from before, with the old trust name and no post, are put in Linear like new ones")
    func migration() async throws {
        let state = try State.decoded(from: Data("""
        {"workspaces": {"w": {"processedIssueIds": [], "lastPollTimestamp": "2027-01-15T07:00:00Z", "proposals": [
          {"id": "old-1", "payload": {"closeIssue": {}}, "target": {"kind": "issue", "id": "i1", "name": "I1"},
           "reason": "moot", "source": {"kind": "commitRange", "value": "a..b"}, "createdAt": "2027-01-10T04:30:00Z",
           "status": "pending", "trust": "standup", "firstShownAt": "2027-01-11T04:30:00Z"},
          {"id": "old-2", "payload": {"postProjectUpdate": {"body": "Hi"}}, "target": {"kind": "project", "id": "pr"},
           "reason": "r", "source": {"kind": "agentSession", "value": "s"}, "createdAt": "2027-01-10T04:30:00Z",
           "status": "applied", "trust": "auto", "decidedAt": "2027-01-10T04:31:00Z"}
        ]}}}
        """.utf8))
        let proposals = state.proposals(workspace: "w")
        #expect(proposals.map(\.trust) == [.review, .auto])
        #expect(proposals[0].post == nil)
        #expect(!proposals[0].isPosted)
        // Not in Linear yet, it does not expire however old.
        var expiring = state
        #expect(expiring.expireProposals(olderThanDays: 1, workspace: "w", now: now).isEmpty)

        let linear = FakeLinear(issues: [issue("i1")])
        let posted = try await poster(linear).post(proposals[0], now: now).proposal
        #expect(posted.isPosted)
        #expect(posted.post?.form == .comment)
        #expect(posted.post?.postedAt == now)
        // The post survives the state file.
        var saved = State()
        saved.recordProposal(posted, workspace: "w")
        #expect(try State.decoded(from: saved.encoded()).proposals(workspace: "w") == [posted])
    }

    @Test("The listing says where a pending proposal waits")
    func listing() async throws {
        let linear = FakeLinear(issues: [issue("i1")])
        let posted = try await poster(linear).post(proposal(.closeIssue), now: now.addingTimeInterval(-60)).proposal
        let text = ProposalsCommand.rendered([posted, proposal(.promoteIssue, id: "p2")], workspace: "w", now: now)
        #expect(text.contains("closeIssue → issue I1  [in Linear]"))
        #expect(text.contains("in Linear: a comment on I1, https://linear.app/t/issue/I1#comment-c1, since"))
        #expect(text.contains("promoteIssue → issue I1  [to be put in Linear]"))
    }
}
