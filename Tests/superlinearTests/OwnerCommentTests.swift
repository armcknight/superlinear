import Foundation
import Testing
@testable import superlinear

/// Linear as answering the owner's comments sees it: issues with labels,
/// and every write recorded.
private actor CommentLinear: LinearWriting {
    var issues: [LinearIssue.ID: EditableIssue] = [:]
    var writes: [String] = []
    var replies: [(target: CommentTarget, parentId: LinearComment.ID, body: String)] = []

    init(issues: [EditableIssue]) {
        self.issues = Dictionary(uniqueKeysWithValues: issues.map { ($0.id, $0) })
    }

    func editableIssue(id: LinearIssue.ID) async throws -> EditableIssue {
        guard let issue = issues[id] else { throw LinearClientError.apiError(["Entity not found"]) }
        return issue
    }

    func openIssues(like title: String, teamId: LinearTeam.ID) async throws -> [IssueMatch] { [] }
    func labelId(named name: String, teamId: LinearTeam.ID) async throws -> LinearLabel.ID { LinearLabel.ID(rawValue: name) }

    func createIssue(
        teamId: LinearTeam.ID, projectId: LinearProject.ID?, title: String, description: String,
        labelIds: [LinearLabel.ID], stateId: LinearState.ID?
    ) async throws -> CreatedIssue {
        writes.append("create \(title)")
        return CreatedIssue(id: "new", identifier: "NEW-1", url: nil, response: .null)
    }

    func updateIssueDescription(id: LinearIssue.ID, description: String) async throws -> JSONValue {
        issues[id]?.description = description
        writes.append("edit \(id)")
        return .null
    }

    func updateComment(id: LinearComment.ID, body: String) async throws -> JSONValue {
        writes.append("update comment \(id): \(body.split(separator: "\n").first ?? "")")
        return .null
    }

    func addLabel(issueId: LinearIssue.ID, labelId: LinearLabel.ID) async throws -> JSONValue {
        issues[issueId]?.labels.append(labelId.rawValue)
        writes.append("label \(issueId) \(labelId)")
        return .null
    }

    func createReply(on target: CommentTarget, parentId: LinearComment.ID, body: String) async throws -> CreatedComment {
        replies.append((target, parentId, body))
        writes.append("reply \(parentId)")
        return CreatedComment(id: LinearComment.ID(rawValue: "reply-\(replies.count)"), url: nil, response: .null)
    }

    func closeIssue(id: LinearIssue.ID) async throws -> JSONValue { .null }
    func promoteIssue(id: LinearIssue.ID) async throws -> JSONValue { .null }
    func createRelation(issueId: LinearIssue.ID, relatedIssueId: LinearIssue.ID, type: String) async throws -> JSONValue { .null }
    func spec(of target: ProposalTarget) async throws -> SpecText { SpecText(content: "", updatedAt: Date()) }
    func updateSpec(of target: ProposalTarget, content: String) async throws -> JSONValue { .null }
    func postProjectUpdate(projectId: LinearProject.ID, body: String) async throws -> JSONValue { .null }
}

private let owner: LinearUser.ID = "owner"
private let base = Date(timeIntervalSince1970: 1_800_000_000)

private func at(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

private func comment(
    _ id: String, _ body: String, by user: LinearUser.ID = owner, at time: Date, edited: Date? = nil, parent: String? = nil
) -> LinearThreadComment {
    LinearThreadComment(
        id: LinearComment.ID(rawValue: id), body: body, userId: user, author: user == owner ? "Owner" : "Someone",
        createdAt: time, editedAt: edited, parentId: parent.map { LinearComment.ID(rawValue: $0) })
}

private func triageProposal(issueId: LinearIssue.ID = "tem-15", postedAt: Date = at(0)) -> Proposal {
    var proposal = Proposal(
        ProposalDraft(
            payload: .createIssue(
                teamId: "team", projectId: nil, title: "vapor-ci.yml: an optional Postgres service for tests",
                description: "Add a Postgres service.", relatedIssueId: nil),
            target: .team("team"), reason: "Tests need a database",
            source: ProposalSource(kind: .agentSession, value: "session", issue: "TEM-3")),
        trust: .review, id: "p-triage", now: at(-60))
    proposal.post = ProposalPost(
        form: .triageIssue, issueId: issueId, issueIdentifier: "TEM-15", url: "https://linear.app/t/issue/TEM-15", postedAt: postedAt)
    return proposal
}

private func commentProposal(issueId: LinearIssue.ID = "spl-4", commentId: LinearComment.ID = "proposal-comment") -> Proposal {
    var proposal = Proposal(
        ProposalDraft(
            payload: .editIssue(oldText: "old", newText: "new"), target: .issue(issueId, name: "SPL-4"), reason: "Clearer",
            source: ProposalSource(kind: .commitRange, value: "abc..def")),
        trust: .review, id: "p-edit", now: at(-60))
    proposal.post = ProposalPost(form: .comment, issueId: issueId, issueIdentifier: "SPL-4", commentId: commentId, postedAt: at(0))
    return proposal
}

private func issue(_ id: LinearIssue.ID, _ state: LinearStateType = .started, _ comments: [LinearThreadComment]) -> IssueComments {
    IssueComments(id: id, identifier: id.rawValue.uppercased(), stateType: state, comments: comments)
}

private func pending(_ id: String, startedAt: Date = at(0)) -> PendingMerge {
    PendingMerge(
        issueId: id, identifier: LinearIssue.Identifier(rawValue: id.uppercased()), branchName: "linear/\(id)",
        reviewsHandledThrough: startedAt, conflictAttempt: nil, stack: nil)
}

@Suite("The owner's comments")
struct OwnerCommentTests {
    // MARK: Questions on proposals

    @Test("A question on a Triage proposal makes one read-only session and one reply in its thread")
    func triageQuestion() async throws {
        let proposal = triageProposal()
        let question = comment("q", "What would be the cost hit to CI to do this?", at: at(347))
        let plan = CommentTriage.plan(
            .init(proposals: [proposal]), issues: [issue("tem-15", .triage, [question])], viewer: owner, now: at(400))
        #expect(plan.answers.count == 1)
        #expect(plan.answers.first?.comment == FreshComment(comment: question))
        #expect(plan.reviews.isEmpty && plan.newAgents.isEmpty)

        let linear = CommentLinear(issues: [
            EditableIssue(
                id: "tem-15", identifier: "TEM-15", description: "", updatedAt: at(0),
                labels: [ProposalEngine.label, ProposalEngine.proposedLabel], stateType: .triage, teamId: "team"),
        ])
        var sessions = 0
        for answer in plan.answers {
            sessions += 1
            let asked = CommentQuestion(answer, since: at(0))
            _ = try await CommentResponder(linear: linear, specDocumentURL: nil)
                .answer(asked, about: proposal, with: CommentAnswer(answer: "About 1 minute per run; free on public repositories."), now: at(500))
        }
        #expect(sessions == 1)
        let replies = await linear.replies
        #expect(replies.count == 1)
        #expect(replies.first?.parentId == "q")
        #expect(replies.first?.target == .issue("tem-15"))
        #expect(replies.first?.body.hasPrefix(CommentMarker.line) == true)
        #expect(await linear.writes == ["reply q"])
    }

    @Test("The question on TEM-15, made after its proposal was posted, is answered on the first poll after the upgrade")
    func firstPollAfterUpgrade() throws {
        let formatter = ISO8601DateFormatter()
        let posted = try #require(formatter.date(from: "2026-10-18T02:42:44Z"))
        let asked = try #require(formatter.date(from: "2026-10-18T02:48:31Z"))
        let older = comment("older", "An older note", at: posted.addingTimeInterval(-3600))
        let question = comment("q", "What would be the cost hit to CI to do this? I assume it would be pretty expensive.", at: asked)
        let plan = CommentTriage.plan(
            .init(proposals: [triageProposal(postedAt: posted)]), issues: [issue("tem-15", .triage, [older, question])],
            viewer: owner, now: asked.addingTimeInterval(600))
        #expect(plan.answers.map(\.comment.comment.id) == ["q"])
        #expect(plan.baselines["tem-15"] == CommentLedger(since: posted))
    }

    @Test("A reply in a proposal comment's thread is a question; a comment outside it is not")
    func commentProposalThread() {
        let proposal = commentProposal()
        let reply = comment("r", "Why this wording?", at: at(10), parent: "proposal-comment")
        let elsewhere = comment("e", "Unrelated note", at: at(20))
        let plan = CommentTriage.plan(
            .init(proposals: [proposal]),
            issues: [issue("spl-4", .unstarted, [comment("proposal-comment", "**superlinear proposes** to update", at: at(0)), reply, elsewhere])],
            viewer: owner, now: at(30))
        #expect(plan.answers.map(\.comment.comment.id) == ["r"])
        #expect(plan.answers.first?.thread.map(\.id) == ["proposal-comment", "r"])
    }

    @Test("A request for a change edits the proposal and replies, and the proposal still waits")
    func changeRequest() async throws {
        let linear = CommentLinear(issues: [
            EditableIssue(
                id: "tem-15", identifier: "TEM-15", description: "", updatedAt: at(0), labels: [ProposalEngine.label],
                stateType: .triage, teamId: "team"),
        ])
        let proposal = triageProposal()
        let question = CommentQuestion(
            subject: .proposal(proposal, issueId: "tem-15"), comment: FreshComment(comment: comment("q", "Make it optional", at: at(10))),
            thread: [], key: "tem-15", since: at(0))
        let answered = try await CommentResponder(linear: linear, specDocumentURL: nil).answer(
            question, about: proposal, with: CommentAnswer(answer: "Made it optional.", revision: "Add an optional Postgres service."),
            now: at(20))
        let revised = try #require(answered.revised)
        #expect(revised.status == .pending)
        guard case .createIssue(_, _, _, let description, _) = revised.payload else { Issue.record("not a new issue"); return }
        #expect(description == "Add an optional Postgres service.")
        #expect(await linear.issues["tem-15"]?.description.contains("Add an optional Postgres service.") == true)
        let body = try #require(await linear.replies.first?.body)
        #expect(body.contains("superlinear changed the proposal as asked"))
        // The label comes back, so the proposal shows in the proposals view.
        #expect(await linear.writes == ["edit tem-15", "reply q", "label tem-15 \(ProposalEngine.proposedLabel)"])
    }

    @Test("A request for a change to a proposal comment edits the comment")
    func changeRequestOnComment() async throws {
        let linear = CommentLinear(issues: [
            EditableIssue(
                id: "spl-4", identifier: "SPL-4", description: "", updatedAt: at(0), labels: [ProposalEngine.proposedLabel],
                stateType: .unstarted, teamId: "team"),
        ])
        let proposal = commentProposal()
        let question = CommentQuestion(
            subject: .proposal(proposal, issueId: "spl-4"),
            comment: FreshComment(comment: comment("r", "Say newer", at: at(10), parent: "proposal-comment")),
            thread: [], key: "spl-4", since: at(0))
        let answered = try await CommentResponder(linear: linear, specDocumentURL: nil).answer(
            question, about: proposal, with: CommentAnswer(answer: "Done.", revision: "newer"), now: at(20))
        #expect(answered.revised?.payload == .editIssue(oldText: "old", newText: "newer"))
        #expect(await linear.writes == ["update comment proposal-comment: **superlinear proposes** to update this issue's description.", "reply proposal-comment"])
    }

    @Test("Kinds with no text to change take no revision")
    func revisionKinds() {
        var proposal = commentProposal()
        proposal.payload = .closeIssue
        #expect(ProposalRevision.applying("anything", to: proposal) == nil)
        #expect(ProposalRevision.meaning(.closeIssue) == nil)
        #expect(ProposalRevision.applying("new", to: commentProposal()) == nil)
    }

    // MARK: Agents

    @Test("A comment on an issue with an open pull request queues a review agent with the comment")
    func reviewAgent() {
        let note = comment("c", "Please also handle the empty case", at: at(100))
        let plan = CommentTriage.plan(.init(pendingMerges: [pending("spl-7")]), issues: [issue("spl-7", .started, [note])], viewer: owner, now: at(200))
        let review = plan.reviews["spl-7"]
        #expect(review?.fresh == [FreshComment(comment: note)])
        #expect(review?.context.new.map(\.body) == ["Please also handle the empty case"])
        #expect(plan.answers.isEmpty && plan.newAgents.isEmpty)
    }

    @Test("A comment on a started issue whose agent ended without a pull request queues a new agent")
    func newAgent() {
        let ended = EndedAgent(issueId: "spl-8", identifier: "SPL-8", branchName: "linear/spl-8", startedAt: at(0))
        let note = comment("c", "Keep going, and open the pull request", at: at(100))
        let plan = CommentTriage.plan(.init(ended: [ended]), issues: [issue("spl-8", .started, [note])], viewer: owner, now: at(200))
        #expect(plan.newAgents.map(\.issueId) == ["spl-8"])
        #expect(plan.newAgents.first?.context.new.map(\.body) == ["Keep going, and open the pull request"])

        let done = CommentTriage.plan(.init(ended: [ended]), issues: [issue("spl-8", .completed, [note])], viewer: owner, now: at(200))
        #expect(done.newAgents.isEmpty)
        #expect(done.finished == ["spl-8"])
    }

    @Test("A comment made while an agent runs waits, and is handled once it ends")
    func whileRunning() {
        var run = AgentRun(issueId: "spl-9", identifier: "SPL-9", branchName: "linear/spl-9", sessionId: "s", queuedAt: at(0))
        run.launchedAt = at(10)
        run.pid = 1
        let note = comment("c", "Use the new API", at: at(100))
        let inputs = CommentTriage.Inputs(runs: [run])
        #expect(CommentTriage.issueIds(inputs).isEmpty)
        let during = CommentTriage.plan(inputs, issues: [issue("spl-9", .started, [note])], viewer: owner, now: at(200))
        #expect(during.reviews.isEmpty && during.newAgents.isEmpty)
        #expect(during.baselines["spl-9"] == CommentLedger(since: at(10)))

        // It ended with a pull request: the review agent takes the comment.
        let after = CommentTriage.plan(
            .init(pendingMerges: [PendingMerge(run)], ledgers: during.baselines), issues: [issue("spl-9", .started, [note])],
            viewer: owner, now: at(300))
        #expect(after.reviews["spl-9"]?.fresh.map(\.comment.id) == ["c"])

        // It ended with none: a new agent takes it.
        let ended = EndedAgent(issueId: "spl-9", identifier: "SPL-9", branchName: "linear/spl-9", startedAt: at(10))
        let without = CommentTriage.plan(
            .init(ended: [ended], ledgers: during.baselines), issues: [issue("spl-9", .started, [note])], viewer: owner, now: at(300))
        #expect(without.newAgents.map(\.issueId) == ["spl-9"])
    }

    // MARK: Rules

    @Test("A comment from another user, or superlinear's own reply, does nothing")
    func othersAndOwn() {
        let comments = [
            comment("other", "A question from someone else", by: "someone", at: at(10)),
            comment("mine", CommentMarker.reply("An answer"), at: at(20)),
            comment("proposal", "**superlinear proposes** to cancel this issue.", at: at(30)),
            comment("applied", "**Applied 2026-10-17T20:31:00Z.** superlinear proposed to cancel this issue.", at: at(40)),
        ]
        let plan = CommentTriage.plan(
            .init(proposals: [triageProposal()], pendingMerges: [pending("spl-7")]),
            issues: [issue("tem-15", .triage, comments), issue("spl-7", .started, comments)], viewer: owner, now: at(100))
        #expect(plan.answers.isEmpty)
        #expect(plan.reviews.isEmpty)
    }

    @Test("An edited comment is handled again with its old text; an unchanged one is not")
    func edited() {
        var ledger = CommentLedger(since: at(0))
        let original = comment("c", "Make it optional", at: at(10))
        ledger.handle([FreshComment(comment: original)])
        #expect(ledger.fresh([original], viewer: owner).isEmpty)

        var changed = original
        changed.body = "Make it optional, and only on main"
        changed.editedAt = at(50)
        #expect(ledger.fresh([changed], viewer: owner) == [FreshComment(comment: changed, previousBody: "Make it optional")])
        let context = CommentContext(comments: [changed], fresh: ledger.fresh([changed], viewer: owner))
        #expect(context.new.first?.previousBody == "Make it optional")
        #expect(renderedComments(context.new).contains("before, it said"))
    }

    @Test("Old comments are not answered on the first run")
    func oldComments() {
        let old = comment("old", "A question from before the upgrade", at: at(-100))
        let plan = CommentTriage.plan(
            .init(proposals: [triageProposal()], pendingMerges: [pending("spl-7")]),
            issues: [issue("tem-15", .triage, [old]), issue("spl-7", .started, [old])], viewer: owner, now: at(100))
        #expect(plan.answers.isEmpty && plan.reviews.isEmpty)
    }

    @Test("Each comment is answered once, also after a restart")
    func onceAcrossRestarts() throws {
        let question = comment("q", "How long would it take?", at: at(10))
        var state = State()
        let first = CommentTriage.plan(
            .init(proposals: [triageProposal()]), issues: [issue("tem-15", .triage, [question])], viewer: owner, now: at(20))
        state.recordCommentWatch(first, workspace: "w")
        #expect(first.answers.count == 1)
        state.handleComments(first.answers.map(\.comment), key: "tem-15", since: at(0), workspace: "w")

        let restarted = try State.decoded(from: state.encoded())
        let ledgers = restarted.workspaces["w"]?.commentLedgers ?? [:]
        let again = CommentTriage.plan(
            .init(proposals: [triageProposal()], ledgers: ledgers), issues: [issue("tem-15", .triage, [question])], viewer: owner, now: at(30))
        #expect(again.answers.isEmpty)
    }

    @Test("Ledgers of issues no longer watched are dropped; the spec document's stays")
    func pruning() {
        var state = State()
        state.workspaces["w"] = WorkspaceState()
        state.workspaces["w"]?.commentLedgers = [
            "gone": CommentLedger(since: at(0)), "document:spec": CommentLedger(since: at(0)), "tem-15": CommentLedger(since: at(5)),
        ]
        var plan = CommentTriage.Plan()
        plan.watched = ["tem-15"]
        state.recordCommentWatch(plan, workspace: "w")
        #expect(Set(state.workspaces["w"]?.commentLedgers.keys.map { $0 } ?? []) == ["document:spec", "tem-15"])
        #expect(state.workspaces["w"]?.commentLedgers["tem-15"]?.since == at(5))
    }

    @Test("State files from before comments were answered decode")
    func oldStateFile() throws {
        let json = #"{"workspaces":{"w":{"processedIssueIds":[],"lastPollTimestamp":"2026-10-17T00:00:00Z"}}}"#
        let state = try State.decoded(from: Data(json.utf8))
        #expect(state.workspaces["w"]?.commentLedgers.isEmpty == true)
        #expect(state.workspaces["w"]?.endedAgents.isEmpty == true)
        #expect(state.workspaces["w"]?.commentAnswers.isEmpty == true)
    }

    @Test("superlinear's marker and proposal comments are its own; the owner's are not")
    func marker() {
        #expect(CommentMarker.isOwn(CommentMarker.reply("Hello")))
        #expect(CommentMarker.isOwn("**superlinear proposes again** to cancel this issue."))
        #expect(CommentMarker.isOwn("**Superseded 2026-10-17T20:31:00Z.** superlinear proposed to cancel this issue."))
        #expect(CommentMarker.isOwn("**Expired 2026-10-17T20:31:00Z.** superlinear proposed this issue"))
        #expect(CommentMarker.isOwn("**Not applied 2026-10-17T20:31:00Z.** The issue changed."))
        #expect(!CommentMarker.isOwn("What would this cost?"))
        #expect(!CommentMarker.isOwn("I think **superlinear proposes** too much"))
    }

    // MARK: The spec document

    @Test("A question on the spec document gets a reply in its thread; a change request makes a changeSpec proposal")
    func specDocument() async throws {
        let document = DocumentComments(
            id: "spec", documentContentId: "content", content: "The spec.", updatedAt: at(0),
            comments: [
                comment("old", "From before", at: at(-10)),
                comment("q", "This should also cover X", at: at(10)),
                comment("other", "Someone else's", by: "someone", at: at(20)),
            ])
        let questions = CommentQuestion.spec(document, url: "https://linear.app/doc", ledger: CommentLedger(since: at(0)), viewer: owner)
        #expect(questions.map(\.comment.comment.id) == ["q"])
        let question = try #require(questions.first)
        #expect(question.key == "document:spec")
        #expect(question.target == .document(contentId: "content"))

        let draft = CommentQuestion.specDraft("The spec, covering X.", document: document, comment: question.comment.comment)
        #expect(draft.payload == .changeSpec(oldText: "The spec.", newText: "The spec, covering X."))
        #expect(draft.target == .document("spec"))
        #expect(draft.source.kind == .comment)
        #expect(draft.targetUpdatedAt == at(0))

        let linear = CommentLinear(issues: [])
        var proposal = Proposal(draft, trust: .review, id: "p-spec", now: at(30))
        proposal.post = ProposalPost(form: .triageIssue, issueId: "spec-1", issueIdentifier: "SPL-50", url: "https://linear.app/i/SPL-50", postedAt: at(30))
        let text = CommentResponder.specReply("It would cover X.", proposal: proposal, asked: true)
        _ = try await CommentResponder(linear: linear, specDocumentURL: nil).reply(to: question, text: text)
        let reply = try #require(await linear.replies.first)
        #expect(reply.target == .document(contentId: "content"))
        #expect(reply.parentId == "q")
        #expect(reply.body.contains("[SPL-50](https://linear.app/i/SPL-50)"))
        #expect(CommentResponder.specReply("No change.", proposal: nil, asked: false) == "No change.")
    }

    // MARK: Sessions

    @Test("The session's answer is read alone, in a code block, or after other text")
    func parse() throws {
        #expect(try CommentAnswer.parse(#"{"answer": "Yes.", "revision": null}"#) == CommentAnswer(answer: "Yes."))
        #expect(try CommentAnswer.parse("Here it is:\n```json\n{\"answer\": \"Yes.\", \"revision\": \"new\"}\n```") == CommentAnswer(answer: "Yes.", revision: "new"))
        #expect(try CommentAnswer.parse("I looked. {\"answer\": \"Yes.\", \"revision\": \"  \"}") == CommentAnswer(answer: "Yes."))
        #expect(throws: CommentAnswerError.self) { try CommentAnswer.parse("No JSON here") }
        #expect(throws: CommentAnswerError.self) { try CommentAnswer.parse(#"{"answer": " "}"#) }
        #expect(throws: CommentAnswerError.self) { try CommentAnswer.parse(#"{"answer": "*Written by superlinear.*\n\n"}"#) }
    }

    @Test("An answer that copies the marker line and superlinear's notes gives a reply with each one time")
    func bareAnswer() async throws {
        let copied = "\(CommentMarker.line)\n\nI added (a).\n\n\(CommentResponder.revisedNote)"
        let answer = try CommentAnswer.parse(String(data: try JSONEncoder().encode(["answer": copied]), encoding: .utf8)!)
        #expect(answer.answer == "I added (a).")

        let linear = CommentLinear(issues: [
            EditableIssue(
                id: "tem-15", identifier: "TEM-15", description: "", updatedAt: at(0), labels: [ProposalEngine.label],
                stateType: .triage, teamId: "team"),
        ])
        let question = CommentQuestion(
            subject: .proposal(triageProposal(), issueId: "tem-15"),
            comment: FreshComment(comment: comment("q", "Add (a)", at: at(10))), thread: [], key: "tem-15", since: at(0))
        let reply = try await CommentResponder(linear: linear, specDocumentURL: nil)
            .answer(question, about: triageProposal(), with: CommentAnswer(answer: answer.answer, revision: "New text"), now: at(20))
        #expect(reply.revised != nil)
        let body = try #require(await linear.replies.first?.body)
        #expect(body.components(separatedBy: CommentMarker.line).count == 2)
        #expect(body.components(separatedBy: CommentResponder.revisedNote).count == 2)

        #expect(CommentResponder.bare("Yes.\n\nIt costs 2 minutes.") == "Yes.\n\nIt costs 2 minutes.")
        let quoted = "Each reply starts with \(CommentMarker.line)\n\n\(CommentMarker.line)\n\nand \(CommentResponder.noChangeNote) is its note.\n\nThat is all."
        #expect(CommentResponder.bare(quoted) == quoted)
        #expect(CommentResponder.bare("\(CommentMarker.line)\n\nIt covers X.\n\n\(CommentResponder.proposedNotePrefix)[SPL-50](https://linear.app/i/SPL-50), in Triage. The document changes only when you accept it.\n\n\(CommentResponder.noChangeNote)") == "It covers X.")
        #expect(CommentResponder.specReply(CommentResponder.bare("No.\n\n\(CommentResponder.noChangeNote)"), proposal: nil, asked: true)
            == "No.\n\n\(CommentResponder.noChangeNote)")
    }

    @Test("The session's prompt has the proposal, its source, the thread and the comment, and asks for JSON")
    func prompt() {
        let proposal = triageProposal()
        let question = CommentQuestion(
            subject: .proposal(proposal, issueId: "tem-15"),
            comment: FreshComment(comment: comment("q", "What would it cost?", at: at(10))),
            thread: [comment("before", "Earlier note", at: at(5)), comment("q", "What would it cost?", at: at(10))], key: "tem-15", since: at(0))
        let text = CommentAnswerPrompt.render(question)
        #expect(text.contains("You only read"))
        #expect(text.contains("vapor-ci.yml: an optional Postgres service for tests"))
        #expect(text.contains("Source: agent session session for TEM-3"))
        #expect(text.contains("Earlier note"))
        #expect(text.contains("What would it cost?"))
        #expect(text.contains(#"{"answer": "<your answer>", "revision": null}"#))
        #expect(text.contains("the whole new description of the proposed issue"))
        #expect(text.contains("superlinear adds the line \"\(CommentMarker.line)\" at the start of the reply"))
        #expect(!CommentSessionRunner.allowedTools.contains("Write"))
        #expect(!CommentSessionRunner.allowedTools.contains("Edit"))
    }

    // MARK: Prompts

    @Test("An agent's first prompt has the issue's comments")
    func startPrompt() {
        var run = AgentRun(issueId: "i", identifier: "SPL-1", branchName: "b", sessionId: "s")
        #expect(!AgentRunner.prompt(for: run).contains("The Linear issue's comments"))
        run.comments = CommentContext(comments: [comment("c", "Mind the edge case", at: at(0))])
        let prompt = AgentRunner.prompt(for: run)
        #expect(prompt.contains("/armcknight-claude:start"))
        #expect(prompt.contains("The Linear issue's comments"))
        #expect(prompt.contains("  > Mind the edge case"))
        #expect(!run.answersComments)
    }

    @Test("A review agent's prompt has the owner's comments; a new agent's prompt acts on them")
    func commentPrompts() {
        let note = comment("c", "Handle the empty case too", at: at(0))
        let context = CommentContext(comments: [note], fresh: [FreshComment(comment: note)])
        var review = AgentRun(issueId: "i", identifier: "SPL-1", branchName: "b", sessionId: "s", review: ReviewRequest(number: 3, url: "u"))
        review.comments = context
        let reviewText = AgentRunner.prompt(for: review)
        #expect(reviewText.contains("gh pr view 3 --json reviews"))
        #expect(reviewText.contains("The owner commented on the Linear issue"))
        #expect(reviewText.contains("Handle the empty case too"))

        let fresh = AgentRun(issueId: "i", identifier: "SPL-1", branchName: "b", sessionId: "s", comments: context)
        #expect(fresh.answersComments)
        let freshText = AgentRunner.prompt(for: fresh)
        #expect(freshText.contains("ended without opening a pull request"))
        #expect(freshText.contains("Handle the empty case too"))
        #expect(freshText.contains("Do not reply on"))
        #expect(freshText.contains(followUpInstructions))
    }

    @Test("Started issues whose agent ended without a pull request, and not at the usage limit, are found")
    func endedWithoutPullRequest() {
        let issues = [
            LinearIssueStatus(id: "a", identifier: "SPL-1", title: "", branchName: "b-a", state: .init(name: "In Progress", type: "started")),
            LinearIssueStatus(id: "b", identifier: "SPL-2", title: "", branchName: "b-b", state: .init(name: "In Progress", type: "started")),
            LinearIssueStatus(id: "c", identifier: "SPL-3", title: "", branchName: "b-c", state: .init(name: "In Progress", type: "started")),
            LinearIssueStatus(id: "d", identifier: "SPL-4", title: "", branchName: "b-d", state: .init(name: "In Progress", type: "started")),
        ]
        let found = StartedIssueSweep.endedWithoutPullRequest(
            issues: issues, pullRequests: [], processed: ["a", "b", "c"], tracked: ["b"]) { $0 == "SPL-3" }
        #expect(found.map(\.identifier) == ["SPL-1"])
    }
}
