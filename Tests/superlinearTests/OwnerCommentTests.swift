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

    func addReaction(commentId: LinearComment.ID, emoji: String) async throws -> JSONValue {
        writes.append("react \(commentId) \(emoji)")
        return .null
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

    @Test("A comment on an issue with an open pull request goes to a session; a request it finds goes to a review agent")
    func reviewAgent() {
        let note = comment("c", "Please also handle the empty case", at: at(100))
        let plan = CommentTriage.plan(.init(pendingMerges: [pending("spl-7")]), issues: [issue("spl-7", .started, [note])], viewer: owner, now: at(200))
        #expect(plan.issueAnswers.map(\.situation) == [.pullRequest])
        #expect(plan.reviews.isEmpty && plan.answers.isEmpty && plan.newAgents.isEmpty)

        var ledger = CommentLedger(since: at(0))
        ledger.wait([FreshComment(comment: note)], issue: "SPL-7")
        let waited = CommentTriage.plan(
            .init(pendingMerges: [pending("spl-7")], ledgers: ["spl-7": ledger]), issues: [issue("spl-7", .started, [note])],
            viewer: owner, now: at(300))
        let review = waited.reviews["spl-7"]
        #expect(review?.fresh == [FreshComment(comment: note)])
        #expect(review?.context.new.map(\.body) == ["Please also handle the empty case"])
        #expect(waited.issueAnswers.isEmpty)
    }

    @Test("A request on a started issue whose agent ended without a pull request queues a new agent")
    func newAgent() {
        let ended = EndedAgent(issueId: "spl-8", identifier: "SPL-8", branchName: "linear/spl-8", startedAt: at(0))
        let note = comment("c", "Keep going, and open the pull request", at: at(100))
        let plan = CommentTriage.plan(.init(ended: [ended]), issues: [issue("spl-8", .started, [note])], viewer: owner, now: at(200))
        #expect(plan.issueAnswers.map(\.situation) == [.agentEnded])
        #expect(plan.newAgents.isEmpty)

        var ledger = CommentLedger(since: at(0))
        ledger.wait([FreshComment(comment: note)], issue: "SPL-8")
        let waited = CommentTriage.plan(
            .init(ended: [ended], ledgers: ["spl-8": ledger]), issues: [issue("spl-8", .started, [note])], viewer: owner, now: at(300))
        #expect(waited.newAgents.map(\.issueId) == ["spl-8"])
        #expect(waited.newAgents.first?.context.new.map(\.body) == ["Keep going, and open the pull request"])

        let done = CommentTriage.plan(.init(ended: [ended]), issues: [issue("spl-8", .completed, [note])], viewer: owner, now: at(200))
        #expect(done.newAgents.isEmpty)
        #expect(done.finished == ["spl-8"])
    }

    @Test("A request made while an agent runs waits, reaches the next agent after it ends, and stops no agent")
    func whileRunning() throws {
        var run = AgentRun(issueId: "spl-9", identifier: "SPL-9", branchName: "linear/spl-9", sessionId: "s", queuedAt: at(0))
        run.launchedAt = at(10)
        run.pid = 1
        let note = comment("c", "Use the new API", at: at(100))
        #expect(CommentTriage.issueIds(.init(runs: [run]), now: at(1000)).isEmpty)
        // The poll found the comment: a session decides what it is.
        let inputs = CommentTriage.Inputs(runs: [run], found: ["spl-9"], foundSince: at(50))
        #expect(CommentTriage.issueIds(inputs, now: at(1000)) == ["spl-9"])
        let during = CommentTriage.plan(inputs, issues: [issue("spl-9", .started, [note])], viewer: owner, now: at(200))
        #expect(during.issueAnswers.map(\.situation) == [.running])
        #expect(during.reviews.isEmpty && during.newAgents.isEmpty)
        #expect(during.baselines["spl-9"] == CommentLedger(since: at(10)))

        // The session found a request: it waits while the agent runs.
        var ledger = try #require(during.baselines["spl-9"])
        ledger.wait([FreshComment(comment: note)], issue: "SPL-9")
        let still = CommentTriage.plan(
            .init(runs: [run], ledgers: ["spl-9": ledger], found: ["spl-9"]), issues: [issue("spl-9", .started, [note])],
            viewer: owner, now: at(250))
        #expect(still.issueAnswers.isEmpty && still.reviews.isEmpty && still.newAgents.isEmpty)
        #expect(CommentTriage.issueIds(.init(runs: [run], ledgers: ["spl-9": ledger]), now: at(10 + 2 * 86400)).isEmpty)

        // It ended with a pull request: the review agent takes the comment.
        let after = CommentTriage.plan(
            .init(pendingMerges: [PendingMerge(run)], ledgers: ["spl-9": ledger]), issues: [issue("spl-9", .started, [note])],
            viewer: owner, now: at(300))
        #expect(after.reviews["spl-9"]?.fresh.map(\.comment.id) == ["c"])

        // It ended with none: a new agent takes it.
        let ended = EndedAgent(issueId: "spl-9", identifier: "SPL-9", branchName: "linear/spl-9", startedAt: at(10))
        let without = CommentTriage.plan(
            .init(ended: [ended], ledgers: ["spl-9": ledger]), issues: [issue("spl-9", .started, [note])], viewer: owner, now: at(300))
        #expect(without.newAgents.map(\.issueId) == ["spl-9"])

        // Handed to the agent, it waits no more.
        ledger.handle([FreshComment(comment: note)], at: at(300))
        #expect(ledger.waiting.isEmpty)
        #expect(ledger.fresh([note], viewer: owner).isEmpty)
    }

    @Test("A request that waited for an agent whose issue was then done goes to a session again")
    func waitedThenDone() {
        let note = comment("c", "Use the new API", at: at(100))
        var ledger = CommentLedger(since: at(0))
        ledger.wait([FreshComment(comment: note)], issue: "SPL-9")
        let inputs = CommentTriage.Inputs(ledgers: ["spl-9": ledger])
        #expect(CommentTriage.issueIds(inputs, now: at(1000)) == ["spl-9"])
        let plan = CommentTriage.plan(inputs, issues: [issue("spl-9", .completed, [note])], viewer: owner, now: at(300))
        #expect(plan.issueAnswers.map(\.situation) == [.done])
        #expect(plan.watched.contains("spl-9"))
    }

    // MARK: Every issue of the watched teams

    private func handMade(
        _ comments: [LinearThreadComment], id: LinearIssue.ID = "tem-30", state: LinearStateType = .unstarted,
        labels: [String] = ["Needs human"]
    ) -> IssueComments {
        IssueComments(
            id: id, identifier: id.rawValue.uppercased(), stateType: state, comments: comments, stateName: "Todo",
            title: "Create the App Store Connect API keys", description: "Steps in the App Store Connect web UI.", labels: labels,
            teamId: "team", url: "https://linear.app/t/issue/\(id.rawValue.uppercased())")
    }

    private func editable(_ issue: IssueComments, labels: [String]? = nil) -> EditableIssue {
        EditableIssue(
            id: issue.id, identifier: issue.identifier, description: issue.description, updatedAt: at(0),
            labels: labels ?? issue.labels, stateType: issue.stateType, teamId: "team")
    }

    @Test("A question on a hand-made Needs human issue is answered, and the issue gets the replied label")
    func handMadeQuestion() async throws {
        let question = comment("q", "Can these steps be terminal commands or a script?", at: at(100))
        let tem30 = handMade([question])
        let plan = CommentTriage.plan(
            .init(found: ["tem-30"], foundSince: at(0)), issues: [tem30], viewer: owner, now: at(200))
        #expect(plan.issueAnswers.count == 1)
        let answer = try #require(plan.issueAnswers.first)
        #expect(answer.situation == .open)
        #expect(plan.baselines["tem-30"] == CommentLedger(since: at(0)))

        let asked = CommentQuestion(answer, since: at(0))
        let prompt = CommentAnswerPrompt.render(asked, openIssues: [], namedIssues: [])
        #expect(prompt.contains("TEM-30: Create the App Store Connect API keys"))
        #expect(prompt.contains("Labels: Needs human"))
        #expect(prompt.contains("No agent of superlinear's works on it."))

        let linear = CommentLinear(issues: [editable(tem30)])
        _ = try await CommentResponder(linear: linear, specDocumentURL: nil).answer(
            asked, situation: .open, with: CommentAnswer(kind: .question, answer: "Yes: `asc keys create`."), proposal: nil)
        #expect(await linear.writes == ["reply q", "label tem-30 \(CommentResponder.repliedLabel)"])
        #expect(await linear.replies.first?.body == CommentMarker.reply("Yes: `asc keys create`."))
    }

    @Test("A request for a change on a Todo issue edits its description and says so; a hands-off issue is not changed")
    func todoChange() async throws {
        let request = comment("r", "Write the steps as a script", at: at(100))
        let todo = handMade([request], id: "spl-20", labels: [])
        let asked = CommentQuestion(
            try #require(CommentTriage.plan(.init(found: ["spl-20"], foundSince: at(0)), issues: [todo], viewer: owner, now: at(200))
                .issueAnswers.first),
            since: at(0))
        let answer = CommentAnswer(kind: .change, answer: "Made the steps a script.", revision: "Run `scripts/keys.sh`.")

        let linear = CommentLinear(issues: [editable(todo)])
        _ = try await CommentResponder(linear: linear, specDocumentURL: nil).answer(asked, situation: .open, with: answer, proposal: nil)
        #expect(await linear.issues["spl-20"]?.description == "Run `scripts/keys.sh`.")
        #expect(await linear.writes == ["edit spl-20", "reply r", "label spl-20 \(CommentResponder.repliedLabel)"])
        #expect(await linear.replies.first?.body.contains(CommentResponder.describedNote) == true)

        let handsOff = CommentLinear(issues: [editable(todo, labels: [ProposalEngine.handsOffLabel])])
        _ = try await CommentResponder(linear: handsOff, specDocumentURL: nil).answer(asked, situation: .open, with: answer, proposal: nil)
        #expect(await handsOff.writes == ["reply r"])
        #expect(await handsOff.replies.first?.body.contains(CommentResponder.handsOffNote) == true)
    }

    @Test("A request on a done issue makes one createIssue proposal, linked in the reply")
    func doneRequest() async throws {
        let request = comment("r", "Also cover the Fly tokens", at: at(100))
        let done = handMade([request], id: "spl-12", state: .completed, labels: [])
        let plan = CommentTriage.plan(.init(found: ["spl-12"], foundSince: at(0)), issues: [done], viewer: owner, now: at(200))
        #expect(plan.issueAnswers.map(\.situation) == [.done])
        let asked = CommentQuestion(try #require(plan.issueAnswers.first), since: at(0))
        let answer = try CommentAnswer.parse(
            #"{"kind": "change", "answer": "Done in #12; the Fly tokens are new work.", "title": "Store the Fly deploy tokens", "revision": "Store them in 1Password."}"#)

        let draft = try #require(CommentQuestion.issueDraft(answer, issue: done, comment: request))
        #expect(draft.payload == .createIssue(
            teamId: "team", projectId: nil, title: "Store the Fly deploy tokens", description: "Store them in 1Password.", relatedIssueId: "spl-12"))
        #expect(draft.source.kind == .comment)

        var proposal = Proposal(draft, trust: .review, id: "p-new", now: at(210))
        proposal.post = ProposalPost(
            form: .triageIssue, issueId: "new", issueIdentifier: "SPL-60", url: "https://linear.app/t/issue/SPL-60", postedAt: at(220))
        let linear = CommentLinear(issues: [editable(done)])
        _ = try await CommentResponder(linear: linear, specDocumentURL: nil).answer(asked, situation: .done, with: answer, proposal: proposal)
        let body = try #require(await linear.replies.first?.body)
        #expect(body.contains("Done in #12"))
        #expect(body.contains("[SPL-60](https://linear.app/t/issue/SPL-60)"))
        #expect(await linear.writes == ["reply r", "label spl-12 \(CommentResponder.repliedLabel)"])

        // No description from the session: no proposal.
        #expect(CommentQuestion.issueDraft(CommentAnswer(kind: .change, answer: "?"), issue: done, comment: request) == nil)
    }

    @Test("A note such as thanks gets no reply; a request for an agent may have no answer; a question must")
    func notes() throws {
        let thanks = try CommentAnswer.parse(#"{"kind": "note", "answer": ""}"#)
        #expect(thanks.kind == .note && !thanks.replies)
        let handed = try CommentAnswer.parse(#"{"kind": "change", "answer": "", "revision": null}"#)
        #expect(!handed.replies)
        #expect(throws: CommentAnswerError.self) { try CommentAnswer.parse(#"{"kind": "question", "answer": ""}"#) }
        // Answers from before kinds still read.
        #expect(try CommentAnswer.parse(#"{"answer": "Yes", "revision": null}"#) == CommentAnswer(answer: "Yes"))
    }

    @Test("The 👀 reaction is added once per comment")
    func reactionOnce() async throws {
        let linear = CommentLinear(issues: [])
        let asked = CommentQuestion(
            subject: .issue(handMade([]), situation: .open), comment: FreshComment(comment: comment("q", "How?", at: at(10))),
            thread: [], key: "tem-30", since: at(0))
        let seen = try #require(try await CommentResponder.markSeen(asked, ledger: nil, linear: linear))
        #expect(seen.reacted == ["q"])
        let again = try await CommentResponder.markSeen(asked, ledger: try State.decodedLedger(seen), linear: linear)
        #expect(again == nil)
        #expect(await linear.writes == ["react q eyes"])
    }

    @Test("Another user's comment is skipped with a line for the log, as is one on a team not watched")
    func skippedComments() {
        let other = comment("o", "Someone else's question", by: "someone", at: at(100))
        let plan = CommentTriage.plan(
            .init(found: ["tem-30"], foundSince: at(0)), issues: [handMade([other])], viewer: owner, now: at(200))
        #expect(plan.issueAnswers.isEmpty)
        #expect(plan.skipped == ["Skipping Someone's comment o on TEM-30: only the owner's comments are handled"])

        let hits = [
            OwnerCommentHit(id: "a", body: "A question", issueId: "tem-30", identifier: "TEM-30", teamId: "team"),
            OwnerCommentHit(id: "b", body: "Elsewhere", issueId: "x-1", identifier: "X-1", teamId: "other"),
            OwnerCommentHit(id: "c", body: CommentMarker.reply("Mine"), issueId: "tem-31", identifier: "TEM-31", teamId: "team"),
            OwnerCommentHit(id: "d", body: "On a document", issueId: nil, identifier: nil, teamId: nil),
        ]
        let found = CommentTriage.found(hits, teamIds: ["team"], backfill: false, excluded: [])
        #expect(found.issueIds == ["tem-30"])
        #expect(found.skipped == ["Skipping the owner's comment b on X-1: its team is not watched"])
        // With no teams set, every team is watched.
        #expect(CommentTriage.found(hits, teamIds: [], backfill: false, excluded: []).issueIds == ["tem-30", "x-1"])
    }

    @Test("The first poll after the upgrade answers comments the old rule skipped, since the first ledger")
    func backfill() throws {
        let formatter = ISO8601DateFormatter()
        let installed = try #require(formatter.date(from: "2026-10-17T20:00:00Z"))
        let asked = try #require(formatter.date(from: "2026-10-18T19:32:35Z"))
        let ledgers: [CommentLedger.Key: CommentLedger] = [
            "tem-15": CommentLedger(since: installed), "document:spec": CommentLedger(since: installed.addingTimeInterval(60)),
        ]
        let start = CommentTriage.backfillStart(ledgers, now: asked.addingTimeInterval(86400))
        #expect(start == installed)
        #expect(CommentTriage.backfillStart([:], now: asked) == asked)

        let hits = [
            OwnerCommentHit(id: "q", body: "Can these be terminal commands?", issueId: "tem-30", identifier: "TEM-30", teamId: "team"),
            OwnerCommentHit(id: "w", body: "Use the new API", issueId: "tem-7", identifier: "TEM-7", teamId: "team"),
        ]
        let found = CommentTriage.found(hits, teamIds: ["team"], backfill: true, excluded: ["tem-7"])
        #expect(found.issueIds == ["tem-30"])

        let question = comment("q", "Can these be terminal commands?", at: asked)
        let older = comment("old", "From before superlinear answered comments", at: installed.addingTimeInterval(-60))
        let plan = CommentTriage.plan(
            .init(ledgers: ledgers, found: found.issueIds, foundSince: start), issues: [handMade([older, question])], viewer: owner,
            now: asked.addingTimeInterval(86400))
        #expect(plan.issueAnswers.map(\.comment.comment.id) == ["q"])
    }

    @Test("An issue whose ledger is less than a day old is read again, so a comment queued at a restart is found")
    func recentLedgers() {
        let ledgers: [CommentLedger.Key: CommentLedger] = ["tem-30": CommentLedger(since: at(100))]
        #expect(CommentTriage.issueIds(.init(ledgers: ledgers), now: at(200)) == ["tem-30"])
        #expect(CommentTriage.plan(.init(ledgers: ledgers), issues: [], viewer: owner, now: at(200)).watched == ["tem-30"])
        #expect(CommentTriage.issueIds(.init(ledgers: ledgers), now: at(100 + CommentTriage.recentLedger + 1)).isEmpty)
    }

    @Test("A comment superlinear replied to already is not answered again when its issue is watched anew")
    func repliedAlready() {
        let question = comment("q", "How?", at: at(100))
        let reply = comment("r", CommentMarker.reply("Like this."), at: at(110), parent: "q")
        let plan = CommentTriage.plan(
            .init(found: ["tem-30"], foundSince: at(0)), issues: [handMade([question, reply])], viewer: owner, now: at(200))
        #expect(plan.issueAnswers.isEmpty)
    }

    @Test("Ledgers of issues handled lately are kept for edits; waiting comments decode from the state file")
    func ledgerRetention() throws {
        var ledger = CommentLedger(since: at(0))
        ledger.handle([FreshComment(comment: comment("q", "How?", at: at(10)))], at: at(20))
        ledger.wait([FreshComment(comment: comment("w", "Use the new API", at: at(30)))], issue: "SPL-9")
        ledger.reacted = ["q"]
        let decoded = try State.decodedLedger(ledger)
        #expect(decoded == ledger)

        var old = CommentLedger(since: at(0))
        old.handle([FreshComment(comment: comment("q", "How?", at: at(10)))], at: at(20))
        let recent = CommentTriage.plan(.init(ledgers: ["recent": old]), issues: [], viewer: owner, now: at(86400))
        #expect(recent.watched.contains("recent"))
        let stale = CommentTriage.plan(
            .init(ledgers: ["stale": old]), issues: [], viewer: owner, now: at(20 + CommentTriage.ledgerRetention + 1))
        #expect(!stale.watched.contains("stale"))

        let json = #"{"since":"2026-10-17T00:00:00Z","handled":{"q":"How?"}}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fromBefore = try decoder.decode(CommentLedger.self, from: Data(json.utf8))
        #expect(fromBefore.waiting.isEmpty && fromBefore.reacted.isEmpty && fromBefore.handledAt == nil)
    }

    @Test("superlinear status lists the requests that wait for an agent")
    func statusWaiting() {
        var state = State()
        state.waitComments(
            [FreshComment(comment: LinearThreadComment(
                id: "w", body: "Use the new API\nand say why", userId: owner, createdAt: at(30), url: "https://linear.app/c/w"))],
            key: "spl-9", since: at(0), identifier: "SPL-9", workspace: "w")
        let waiting = state.waitingComments(workspace: "w")
        #expect(waiting.map(\.summary) == ["Use the new API"])
        let report = WorkspaceReport(name: "w", entries: [], commentsWaiting: waiting, warnings: [])
        let text = report.rendered(now: at(100))
        #expect(text.contains(WorkspaceReport.commentsWaitingHeading))
        #expect(text.contains("SPL-9  Use the new API"))
        #expect(text.contains("https://linear.app/c/w"))
        #expect(report.filtered(to: [.done]).commentsWaiting.isEmpty)
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
        #expect(CommentResponder.bare("\(CommentResponder.revisedNote)\n\nIt still waits.") == "\(CommentResponder.revisedNote)\n\nIt still waits.")
        #expect(CommentResponder.bare("Yes.\n\n\(CommentResponder.proposedNotePrefix)a new issue.") == "Yes.\n\n\(CommentResponder.proposedNotePrefix)a new issue.")
        #expect(CommentResponder.bare("\(CommentMarker.line)\n\n\(CommentResponder.revisedNote)") == "")
        #expect(CommentResponder.bare("") == "")
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
        let text = CommentAnswerPrompt.render(question, openIssues: [], namedIssues: [])
        #expect(text.contains("You only read"))
        #expect(text.contains("vapor-ci.yml: an optional Postgres service for tests"))
        #expect(text.contains("Source: agent session session for TEM-3"))
        #expect(text.contains("Earlier note"))
        #expect(text.contains("What would it cost?"))
        #expect(text.contains(#"{"kind": "question", "answer": "<your answer>", "revision": null}"#))
        #expect(text.contains("the whole new description of the proposed issue"))
        #expect(text.contains("superlinear adds the line \"\(CommentMarker.line)\" at the start of the reply"))
        #expect(!CommentSessionRunner.allowedTools.contains("Write"))
        #expect(!CommentSessionRunner.allowedTools.contains("Edit"))
    }

    @Test("The answer session may read Linear issues with linctl, and write nothing there")
    func linctlTools() {
        let tools = CommentSessionRunner.allowedTools.split(separator: ",").map(String.init)
        for command in ["get", "list", "search"] { #expect(tools.contains("Bash(linctl issue \(command):*)")) }
        let linctl = tools.filter { $0.contains("linctl") }
        #expect(Set(linctl) == Set(["get", "list", "search"].map { "Bash(linctl issue \($0):*)" }))
        #expect(!tools.contains { $0.contains("linctl issue update") || $0.contains("linctl comment") || $0 == "Bash(linctl:*)" })
        #expect(CommentAnswerPrompt.render(triageQuestion("Hi"), openIssues: [], namedIssues: []).contains(LinearKey.promptLine))
    }

    @Test("A comment's prompt has the workspace's issues it and the proposal name, not other teams' or its own")
    func namedIssues() {
        let question = triageQuestion("Is this a duplicate of TEM-22? See also ABC-1, TEM-22 and TEM-15.")
        let identifiers = CommentAnswerPrompt.namedIdentifiers(question, teamKeys: ["TEM"])
        // TEM-3 is the proposal's source; ABC is no team of the workspace; TEM-15 is the issue the comment is on.
        #expect(identifiers == ["TEM-22", "TEM-3"])

        let duplicate = PlanningIssue(
            id: "tem-22", identifier: "TEM-22", title: "Postgres for the tests", description: "A database service in CI.",
            stateName: "Todo", stateType: .unstarted, priority: nil, teamId: "team", teamKey: "TEM", projectId: nil,
            projectName: nil, milestone: nil, labels: ["ci"],
            relations: [PlanningRelation(type: .blocks, identifier: "TEM-30", direction: .outgoing)], updatedAt: at(0))
        let text = CommentAnswerPrompt.render(question, openIssues: [], namedIssues: [duplicate])
        #expect(text.contains("- TEM-22: Postgres for the tests\n  - State: Todo\n  - Labels: ci\n  - Relations: blocks TEM-30"))
        #expect(text.contains("A database service in CI."))
        #expect(!CommentAnswerPrompt.render(question, openIssues: [], namedIssues: []).contains("issues that the comment names"))
    }

    @Test("A comment names at most a few issues")
    func namedIssuesLimit() {
        let body = (1...20).map { "TEM-\($0 + 100)" }.joined(separator: " ")
        #expect(CommentAnswerPrompt.namedIdentifiers(triageQuestion(body), teamKeys: ["TEM"]).count == CommentAnswerPrompt.maxNamedIssues)
    }

    private func triageQuestion(_ body: String) -> CommentQuestion {
        CommentQuestion(
            subject: .proposal(triageProposal(), issueId: "tem-15"), comment: FreshComment(comment: comment("q", body, at: at(10))),
            thread: [], key: "tem-15", since: at(0))
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

private extension State {
    /// The ledger as the state file keeps it, written and read again.
    static func decodedLedger(_ ledger: CommentLedger) throws -> CommentLedger? {
        var state = State()
        state.workspaces["w"] = WorkspaceState()
        state.workspaces["w"]?.commentLedgers["k"] = ledger
        return try State.decoded(from: state.encoded()).workspaces["w"]?.commentLedgers["k"]
    }
}
