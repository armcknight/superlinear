import Foundation
import Testing
@testable import superlinear

/// Linear as proposals see it, kept in memory, recording every write.
private actor FakeLinear: LinearWriting {
    var issues: [LinearIssue.ID: EditableIssue] = [:]
    var openMatches: [IssueMatch] = []
    var specs: [String: SpecText] = [:]
    var labels: [String: LinearLabel.ID] = [:]
    var writes: [String] = []
    var failWrites = false

    init(issues: [EditableIssue] = [], openMatches: [IssueMatch] = []) {
        self.issues = Dictionary(uniqueKeysWithValues: issues.map { ($0.id, $0) })
        self.openMatches = openMatches
    }

    func setFailWrites(_ fail: Bool) { failWrites = fail }

    private func written(_ description: String) throws -> JSONValue {
        if failWrites { throw LinearClientError.apiError(["offline"]) }
        writes.append(description)
        return .object(["success": .bool(true), "write": .string(description)])
    }

    func editableIssue(id: LinearIssue.ID) async throws -> EditableIssue {
        guard let issue = issues[id] else { throw LinearClientError.apiError(["Entity not found"]) }
        return issue
    }

    func openIssues(like title: String, teamId: LinearTeam.ID) async throws -> [IssueMatch] { openMatches }

    func labelId(named name: String, teamId: LinearTeam.ID) async throws -> LinearLabel.ID {
        if let id = labels[name] { return id }
        labels[name] = LinearLabel.ID(rawValue: "label-\(labels.count)")
        writes.append("create label \(name)")
        return labels[name]!
    }

    func createIssue(
        teamId: LinearTeam.ID, projectId: LinearProject.ID?, title: String, description: String, labelIds: [LinearLabel.ID]
    ) async throws -> JSONValue {
        try written("create \(title) labels=\(labelIds.map(\.rawValue)) description=\(description)")
    }

    func updateIssueDescription(id: LinearIssue.ID, description: String) async throws -> JSONValue {
        let response = try written("edit \(id)")
        issues[id]?.description = description
        return response
    }

    func closeIssue(id: LinearIssue.ID) async throws -> JSONValue { try written("close \(id)") }
    func promoteIssue(id: LinearIssue.ID) async throws -> JSONValue { try written("promote \(id)") }

    func createRelation(issueId: LinearIssue.ID, relatedIssueId: LinearIssue.ID, type: String) async throws -> JSONValue {
        try written("relate \(issueId) \(type) \(relatedIssueId)")
    }

    func spec(of target: ProposalTarget) async throws -> SpecText {
        guard let spec = specs[target.rawID] else { throw LinearClientError.apiError(["Entity not found"]) }
        return spec
    }

    func setSpec(_ spec: SpecText, id: String) { specs[id] = spec }

    func updateSpec(of target: ProposalTarget, content: String) async throws -> JSONValue {
        try written("spec \(target.rawID)")
    }

    func postProjectUpdate(projectId: LinearProject.ID, body: String) async throws -> JSONValue {
        try written("update \(projectId) \(body)")
    }
}

private let source = ProposalSource(kind: .pullRequest, value: "https://github.com/o/r/pull/7")
private let proposedAt = Date(timeIntervalSince1970: 1_700_000_000)

private func issue(
    _ id: String = "i1", description: String = "", labels: [String] = [], state: LinearStateType = .backlog,
    updatedAt: Date = proposedAt
) -> EditableIssue {
    EditableIssue(
        id: LinearIssue.ID(rawValue: id), identifier: id.uppercased(), description: description, updatedAt: updatedAt,
        labels: labels, stateType: state, teamId: "team"
    )
}

private func draft(
    _ payload: ProposalPayload, target: ProposalTarget = .issue("i1"),
    updatedAt: Date? = proposedAt
) -> ProposalDraft {
    ProposalDraft(payload: payload, target: target, reason: "because", source: source, targetUpdatedAt: updatedAt)
}

private func newIssue(_ title: String, relatedTo related: LinearIssue.ID? = nil) -> ProposalDraft {
    draft(
        .createIssue(teamId: "team", projectId: nil, title: title, description: "Do it.", relatedIssueId: related),
        target: .team("team"), updatedAt: nil
    )
}

private func engine(
    _ linear: FakeLinear, autonomy: Autonomy = Autonomy(), audit: AuditLog = AuditLog(directory: scratch())
) -> ProposalEngine {
    ProposalEngine(workspace: "w", autonomy: autonomy, linear: linear, audit: audit)
}

private func scratch() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("superlinear-\(UUID().uuidString)")
}

private func stored(_ screening: ProposalEngine.Screening) throws -> (Proposal, Bool) {
    guard case .store(let proposal, let applyNow) = screening else {
        throw ProposalTestError.notStored("\(screening)")
    }
    return (proposal, applyNow)
}

private enum ProposalTestError: Error {
    case notStored(String)
}

@Suite("Proposal trust levels")
struct TrustLevelTests {
    @Test("By default relations apply at once and everything else waits for standup")
    func defaults() {
        let autonomy = Autonomy()
        for kind in ProposalKind.allCases {
            #expect(autonomy.level(for: kind) == (kind == .addRelation ? .auto : .standup))
        }
    }

    @Test("An auto proposal is stored to apply now, a standup one to wait")
    func autoAppliesNow() async throws {
        let linear = FakeLinear(issues: [issue()])
        let (relation, relationNow) = try stored(await engine(linear).screen(
            draft(.addRelation(relatedIssueId: "i2", type: "blocks")), existing: []
        ))
        #expect(relationNow)
        #expect(relation.trust == .auto && relation.status == .pending)

        let (close, closeNow) = try stored(await engine(linear).screen(draft(.closeIssue), existing: []))
        #expect(!closeNow)
        #expect(close.trust == .standup)
    }

    @Test("A kind set to never is not proposed, and config overrides apply")
    func overrides() async throws {
        let linear = FakeLinear(issues: [issue()])
        let autonomy = Autonomy(overrides: [.addRelation: .never, .closeIssue: .auto])
        let relation = try await engine(linear, autonomy: autonomy)
            .screen(draft(.addRelation(relatedIssueId: "i2", type: "blocks")), existing: [])
        guard case .skip = relation else {
            Issue.record("A relation set to never was stored: \(relation)")
            return
        }
        let (_, closeNow) = try stored(await engine(linear, autonomy: autonomy).screen(draft(.closeIssue), existing: []))
        #expect(closeNow)
    }
}

@Suite("Proposal duplicates")
struct ProposalDuplicateTests {
    @Test("A rejected proposal is not proposed again with the same kind and target")
    func rejectedNotAgain() async throws {
        let linear = FakeLinear(issues: [issue()])
        var state = State()
        let (proposal, _) = try stored(await engine(linear).screen(draft(.closeIssue), existing: []))
        state.recordProposal(proposal, workspace: "w")
        let rejected = state.rejectProposal(id: proposal.id, reason: "keep it", workspace: "w")
        #expect(rejected)

        let again = try await engine(linear).screen(draft(.closeIssue), existing: state.proposals(workspace: "w"))
        guard case .skip(let reason) = again else {
            Issue.record("A rejected proposal was proposed again")
            return
        }
        #expect(reason.contains("rejected"))

        // Another target is another proposal.
        _ = try stored(await engine(linear).screen(
            draft(.closeIssue, target: .issue("i2")), existing: state.proposals(workspace: "w")
        ))
    }

    @Test("A pending proposal is not stored twice, but an expired one may come again")
    func pendingNotTwice() async throws {
        let linear = FakeLinear()
        var (proposal, _) = try stored(await engine(linear).screen(newIssue("Add retries"), existing: []))
        let twice = try await engine(linear).screen(newIssue("add  retries!"), existing: [proposal])
        guard case .skip = twice else {
            Issue.record("The same new issue was stored twice")
            return
        }
        proposal.status = .expired
        _ = try stored(await engine(linear).screen(newIssue("Add retries"), existing: [proposal]))
    }

    @Test("A new issue like an open one is not proposed")
    func duplicateIssueDropped() async throws {
        let linear = FakeLinear(openMatches: [IssueMatch(id: "i9", identifier: "SPL-9", title: "Add retries to the sync")])
        let screening = try await engine(linear).screen(newIssue("Add retry to the sync"), existing: [])
        guard case .skip(let reason) = screening else {
            Issue.record("A duplicate issue was stored: \(screening)")
            return
        }
        #expect(reason.contains("SPL-9"))
    }

    @Test("A new issue like an open one, following from another, becomes a relation")
    func duplicateBecomesRelation() async throws {
        let linear = FakeLinear(openMatches: [IssueMatch(id: "i9", identifier: "SPL-9", title: "Add retries to the sync")])
        let (proposal, applyNow) = try stored(await engine(linear).screen(
            newIssue("Add retries to the sync", relatedTo: "i3"), existing: []
        ))
        #expect(proposal.payload == .addRelation(relatedIssueId: "i9", type: "related"))
        #expect(proposal.target == .issue("i3"))
        #expect(applyNow)
    }

    @Test("An open issue with an unlike title does not stop a new one")
    func unlikeTitle() async throws {
        let linear = FakeLinear(openMatches: [IssueMatch(id: "i9", identifier: "SPL-9", title: "Rewrite the status report")])
        let (proposal, _) = try stored(await engine(linear).screen(newIssue("Add retries to the sync"), existing: []))
        #expect(proposal.kind == .createIssue)
    }

    @Test("Titles match regardless of case and punctuation, and closely")
    func titleMatch() {
        #expect(TitleMatch.isClose("Add retries to the sync", "add retries to the sync."))
        #expect(TitleMatch.isClose("Add retries to the sync", "Add retry to the sync"))
        #expect(!TitleMatch.isClose("Add retries to the sync", "Remove the sync"))
        #expect(!TitleMatch.isClose("Fix login", "Fix logout crash on launch"))
    }
}

@Suite("Proposal expiry")
struct ProposalExpiryTests {
    @Test("Pending proposals older than the expiry expire; others stay")
    func expiry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 24 * 60 * 60
        var state = State()
        let old = Proposal(newIssue("Old"), trust: .standup, id: "old", now: now.addingTimeInterval(-8 * day))
        let fresh = Proposal(newIssue("Fresh"), trust: .standup, id: "fresh", now: now.addingTimeInterval(-6 * day))
        var rejected = Proposal(newIssue("Rejected"), trust: .standup, id: "rejected", now: now.addingTimeInterval(-90 * day))
        rejected.status = .rejected
        rejected.decidedAt = now.addingTimeInterval(-89 * day)
        var applied = Proposal(newIssue("Applied"), trust: .auto, id: "applied", now: now.addingTimeInterval(-40 * day))
        applied.status = .applied
        applied.decidedAt = now.addingTimeInterval(-40 * day)
        for proposal in [old, fresh, rejected, applied] { state.recordProposal(proposal, workspace: "w") }

        let expired = state.expireProposals(olderThanDays: 7, workspace: "w", now: now).map(\.id)

        #expect(expired == ["old"])
        let byId = Dictionary(uniqueKeysWithValues: state.proposals(workspace: "w").map { ($0.id, $0) })
        #expect(byId["old"]?.status == .expired)
        #expect(byId["old"]?.decidedAt == now)
        #expect(byId["fresh"]?.status == .pending)
        // Rejections stay to keep the change from coming back; old applied ones go.
        #expect(byId["rejected"]?.status == .rejected)
        #expect(byId["applied"] == nil)
    }

    @Test("The expiry and autonomy come from the workspace config")
    func config() throws {
        let config = try Config.decoded(from: Data("""
        {"workspaces": [
          {"name": "a", "apiKey": "k", "repoPath": "~/r"},
          {"name": "b", "apiKey": "k", "repoPath": "~/r", "proposalExpiryDays": 3,
           "autonomy": {"createIssue": "auto", "addRelation": "never"}}
        ]}
        """.utf8))
        #expect(config.workspaces[0].proposalExpiryDays == 7)
        #expect(config.workspaces[0].autonomy == Autonomy())
        #expect(config.workspaces[1].proposalExpiryDays == 3)
        #expect(config.workspaces[1].autonomy.level(for: .createIssue) == .auto)
        #expect(config.workspaces[1].autonomy.level(for: .addRelation) == .never)
        #expect(config.workspaces[1].autonomy.level(for: .editIssue) == .standup)
    }

    @Test("An unknown kind or level in autonomy is an error")
    func unknownAutonomy() {
        for autonomy in [#"{"createIssues": "auto"}"#, #"{"createIssue": "always"}"#] {
            #expect(throws: DecodingError.self) {
                try Config.decoded(from: Data("""
                {"workspaces": [{"name": "a", "apiKey": "k", "repoPath": "~/r", "autonomy": \(autonomy)}]}
                """.utf8))
            }
        }
    }
}

@Suite("Applying proposals")
struct ProposalApplyTests {
    @Test("The managed block keeps the owner's text")
    func managedBlock() {
        let owner = "Owner's words.\n\nMore of them."
        let added = ManagedBlock.replacing(in: owner, with: "First note")
        #expect(added == "Owner's words.\n\nMore of them.\n\n<!-- superlinear -->\nFirst note\n<!-- /superlinear -->")
        #expect(ManagedBlock.contents(of: added) == "First note")

        let surrounded = added + "\n\nWritten after."
        let replaced = ManagedBlock.replacing(in: surrounded, with: "Second note")
        #expect(replaced == "Owner's words.\n\nMore of them.\n\n<!-- superlinear -->\nSecond note\n<!-- /superlinear -->\n\nWritten after.")
        #expect(ManagedBlock.replacing(in: "", with: "Only") == "<!-- superlinear -->\nOnly\n<!-- /superlinear -->")
    }

    @Test("An edit to an issue superlinear did not create changes only its managed block")
    func editKeepsOwnerText() async throws {
        let linear = FakeLinear(issues: [issue(description: "Owner's text")])
        let proposal = Proposal(draft(.editIssue(oldText: "", newText: "Blocked by SPL-2")), trust: .standup)
        let result = await engine(linear).apply(proposal)

        #expect(result.status == .applied)
        let description = try #require(await linear.issues["i1"]?.description)
        #expect(description.hasPrefix("Owner's text\n\n"))
        #expect(ManagedBlock.contents(of: description) == "Blocked by SPL-2")
    }

    @Test("An edit to an issue superlinear created replaces its description")
    func editOwnIssue() async throws {
        let linear = FakeLinear(issues: [issue(description: "Old", labels: ["Superlinear"])])
        let result = await engine(linear).apply(Proposal(draft(.editIssue(oldText: "Old", newText: "New")), trust: .standup))
        #expect(result.status == .applied)
        #expect(await linear.issues["i1"]?.description == "New")
    }

    @Test("An issue that changed after the proposal is not overwritten, but goes back for review")
    func changedIssue() async throws {
        let linear = FakeLinear(issues: [issue(description: "Edited by hand", updatedAt: proposedAt.addingTimeInterval(60))])
        for payload in [ProposalPayload.editIssue(oldText: "", newText: "Note"), .closeIssue, .promoteIssue] {
            let result = await engine(linear).apply(Proposal(draft(payload), trust: .auto))
            #expect(result.status == .pending)
            #expect(result.trust == .standup)
            #expect(result.reviewNote?.contains("changed in Linear") == true)
        }
        #expect(await linear.writes.isEmpty)
        #expect(await linear.issues["i1"]?.description == "Edited by hand")
    }

    @Test("Linear's milliseconds, which the state file drops, do not count as a change")
    func subsecondUpdate() async throws {
        let linear = FakeLinear(issues: [issue(updatedAt: proposedAt.addingTimeInterval(0.7))])
        let result = await engine(linear).apply(Proposal(draft(.closeIssue), trust: .standup))
        #expect(result.status == .applied)
    }

    @Test("Without a proposed time, text that differs from the proposal's old text counts as a change")
    func changedText() async throws {
        let linear = FakeLinear(issues: [issue(description: "Old", labels: ["superlinear"])])
        let result = await engine(linear).apply(Proposal(
            draft(.editIssue(oldText: "Older", newText: "New"), updatedAt: nil), trust: .standup
        ))
        #expect(result.status == .pending)
        #expect(result.reviewNote != nil)
    }

    @Test("An issue labelled hands off is never changed")
    func handsOff() async throws {
        let linear = FakeLinear(issues: [issue(labels: ["superlinear: hands off"])])
        for payload in [
            ProposalPayload.editIssue(oldText: "", newText: "Note"), .closeIssue, .promoteIssue,
            .addRelation(relatedIssueId: "i2", type: "related"),
        ] {
            let result = await engine(linear).apply(Proposal(draft(payload), trust: .auto))
            #expect(result.status == .rejected)
            #expect(result.rejectionReason?.contains("hands off") == true)
        }
        #expect(await linear.writes.isEmpty)
    }

    @Test("A new issue gets the superlinear label, created once, and a Source line")
    func createIssue() async throws {
        let linear = FakeLinear()
        for _ in 0..<2 {
            let result = await engine(linear).apply(Proposal(newIssue("Add retries"), trust: .standup))
            #expect(result.status == .applied)
        }
        let writes = await linear.writes
        #expect(writes.filter { $0 == "create label superlinear" }.count == 1)
        let created = try #require(writes.last)
        #expect(created.contains("labels=[\"label-0\"]"))
        #expect(created.hasSuffix("Do it.\n\nSource: https://github.com/o/r/pull/7"))
    }

    @Test("A promotion needs the issue still in the backlog")
    func promotion() async throws {
        let linear = FakeLinear(issues: [issue(state: .backlog), issue("i2", state: .unstarted)])
        #expect(await engine(linear).apply(Proposal(draft(.promoteIssue), trust: .standup)).status == .applied)
        let moved = await engine(linear).apply(Proposal(
            draft(.promoteIssue, target: .issue("i2")), trust: .standup
        ))
        #expect(moved.status == .pending)
        #expect(await linear.writes == ["promote i1"])
    }

    @Test("A spec change waits for review when the document changed since")
    func specChange() async throws {
        let linear = FakeLinear()
        await linear.setSpec(SpecText(content: "Spec", updatedAt: proposedAt.addingTimeInterval(3600)), id: "d1")
        let target = ProposalTarget.document("d1", name: "Plan")
        let stale = await engine(linear).apply(Proposal(
            draft(.changeSpec(oldText: "Spec", newText: "Spec v2"), target: target), trust: .standup
        ))
        #expect(stale.status == .pending)
        #expect(stale.reviewNote == "Plan changed in Linear after this was proposed")

        let current = await engine(linear).apply(Proposal(
            draft(.changeSpec(oldText: "Spec", newText: "Spec v2"), target: target, updatedAt: proposedAt.addingTimeInterval(3600)),
            trust: .standup
        ))
        #expect(current.status == .applied)
    }

    @Test("Each applied change goes in the audit log, with Linear's response")
    func auditLog() async throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audit = AuditLog(directory: directory)
        let linear = FakeLinear(issues: [issue()])
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        let applied = await engine(linear, audit: audit).apply(
            Proposal(draft(.addRelation(relatedIssueId: "i2", type: "blocks")), trust: .auto), now: now
        )
        // A change that was not made is not logged.
        await linear.setFailWrites(true)
        let failed = await engine(linear, audit: audit).apply(Proposal(draft(.closeIssue), trust: .standup))
        #expect(failed.status == .pending)
        #expect(failed.lastError?.contains("offline") == true)

        let entries = try audit.entries(workspace: "w")
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.time == now)
        // The log keeps dates to the second, as the state file does.
        #expect(entry.proposal.id == applied.id)
        #expect(entry.proposal.status == .applied)
        #expect(entry.response["write"]?.stringValue == "relate i1 blocks i2")
        #expect(audit.fileURL(workspace: "w").lastPathComponent == "w.jsonl")
    }
}

@Suite("Proposal storage and listing")
struct ProposalStorageTests {
    @Test("Proposals survive the state file, and older state files have none")
    func roundTrip() throws {
        var state = State()
        var proposal = Proposal(
            draft(.editIssue(oldText: "a", newText: "b")), trust: .standup, id: "p1",
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        proposal.reviewNote = "note"
        state.recordProposal(proposal, workspace: "w")
        state.recordProposal(Proposal(newIssue("New"), trust: .standup, id: "p2", now: proposedAt), workspace: "w")

        let decoded = try State.decoded(from: state.encoded())
        #expect(decoded.proposals(workspace: "w") == state.proposals(workspace: "w"))

        let old = try State.decoded(from: Data("""
        {"workspaces": {"w": {"processedIssueIds": [], "lastPollTimestamp": "2024-01-01T00:00:00Z"}}}
        """.utf8))
        #expect(old.proposals(workspace: "w").isEmpty)
    }

    @Test("Targets and tagged IDs keep a plain JSON form in the state file")
    func targetFormat() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let target = ProposalTarget.document("d1", name: "Plan")
        #expect(String(decoding: try encoder.encode(target), as: UTF8.self) == #"{"id":"d1","kind":"document","name":"Plan"}"#)
        #expect(try JSONDecoder().decode(ProposalTarget.self, from: encoder.encode(target)) == target)

        let payload = ProposalPayload.addRelation(relatedIssueId: "i2", type: "blocks")
        let json = String(decoding: try encoder.encode(payload), as: UTF8.self)
        #expect(json.contains(#""relatedIssueId":"i2""#))
    }

    @Test("Rejecting needs a pending proposal")
    func rejectOnlyPending() {
        var state = State()
        var applied = Proposal(newIssue("New"), trust: .auto, id: "p1")
        applied.status = .applied
        state.recordProposal(applied, workspace: "w")
        let rejectedApplied = state.rejectProposal(id: "p1", reason: nil, workspace: "w")
        let rejectedMissing = state.rejectProposal(id: "missing", reason: nil, workspace: "w")
        #expect(!rejectedApplied)
        #expect(!rejectedMissing)
    }

    @Test("The listing shows pending proposals, then recent ones, with diffs")
    func listing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let pending = Proposal(
            draft(.editIssue(oldText: "one\ntwo", newText: "one\nthree"), target: .issue("i1", name: "SPL-1")),
            trust: .standup, id: "aaaaaaaa-1", now: now.addingTimeInterval(-60)
        )
        var applied = Proposal(newIssue("Applied"), trust: .auto, id: "bbbbbbbb-2", now: now.addingTimeInterval(-120))
        applied.status = .applied
        applied.decidedAt = now.addingTimeInterval(-100)
        var old = Proposal(newIssue("Old"), trust: .auto, id: "cccccccc-3", now: now.addingTimeInterval(-30 * 86400))
        old.status = .expired
        old.decidedAt = now.addingTimeInterval(-20 * 86400)

        let text = ProposalsCommand.rendered([old, applied, pending], workspace: "w", now: now)
        #expect(text.contains("  Pending (1)\n    aaaaaaaa  editIssue → issue SPL-1  [awaiting standup]"))
        #expect(text.contains("      - two\n      + three"))
        #expect(text.contains("  Recent (1)\n    bbbbbbbb  createIssue → team team  [applied"))
        #expect(!text.contains("cccccccc"))
        #expect(ProposalsCommand.rendered([], workspace: "w") == "w\n  No proposals")
    }

    @Test("The line diff keeps, removes and adds lines")
    func lineDiff() {
        #expect(LineDiff.lines(from: "a\nb\nc", to: "a\nc\nd") == ["  a", "- b", "  c", "+ d"])
        #expect(LineDiff.lines(from: "", to: "x") == ["+ x"])
    }

    @Test("Sources link back to where a proposal came from")
    func sourceLine() {
        #expect(source.line == "Source: https://github.com/o/r/pull/7")
        #expect(ProposalSource(kind: .commitRange, value: "a..b", url: "https://github.com/o/r/compare/a...b").line
            == "Source: [commits a..b](https://github.com/o/r/compare/a...b)")
        #expect(ProposalSource(kind: .agentSession, value: "s1").line == "Source: agent session s1")
    }
}
