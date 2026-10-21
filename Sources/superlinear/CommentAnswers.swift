import Foundation

/// A question or request from the owner that a read-only Claude session
/// answers: on a pending proposal, on the spec document, or on any other
/// issue of the watched teams.
struct CommentQuestion: Sendable, Equatable {
    enum Subject: Sendable, Equatable {
        /// A proposal waiting in Linear, and the issue the comment is on.
        case proposal(Proposal, issueId: LinearIssue.ID)
        /// The spec document, and its URL when known.
        case spec(DocumentComments, url: String?)
        /// An issue, and where it stood when the poll found the comment.
        case issue(IssueComments, situation: IssueSituation)
    }

    var subject: Subject
    var comment: FreshComment
    /// The comments before it that it may refer to, oldest first, with it.
    var thread: [LinearThreadComment]
    /// The key of the ledger that records it handled.
    var key: CommentLedger.Key
    /// The ledger's baseline, should it have none yet.
    var since: Date

    init(subject: Subject, comment: FreshComment, thread: [LinearThreadComment], key: CommentLedger.Key, since: Date) {
        self.subject = subject
        self.comment = comment
        self.thread = thread
        self.key = key
        self.since = since
    }

    init(_ answer: CommentTriage.Answer, since: Date) {
        self.init(
            subject: .proposal(answer.proposal, issueId: answer.issueId), comment: answer.comment, thread: answer.thread,
            key: .init(answer.issueId), since: since)
    }

    init(_ answer: CommentTriage.IssueAnswer, since: Date) {
        self.init(
            subject: .issue(answer.issue, situation: answer.situation), comment: answer.comment, thread: answer.thread,
            key: .init(answer.issue.id), since: since)
    }

    /// The questions in the owner's fresh comments on the spec document,
    /// each with its thread.
    static func spec(_ document: DocumentComments, url: String?, ledger: CommentLedger, viewer: LinearUser.ID) -> [CommentQuestion] {
        ledger.fresh(document.comments, viewer: viewer).map { fresh in
            let thread = document.comments.filter {
                $0.rootId == fresh.comment.rootId && ($0.createdAt < fresh.comment.createdAt || $0.id == fresh.comment.id)
            }
            return CommentQuestion(
                subject: .spec(document, url: url), comment: fresh, thread: thread, key: .document(document.id),
                since: ledger.since)
        }
    }

    /// The `changeSpec` proposal for the new text of the spec that a
    /// comment on it asked for.
    static func specDraft(_ text: String, document: DocumentComments, comment: LinearThreadComment) -> ProposalDraft {
        let firstLine = comment.body.split(separator: "\n").first.map(String.init) ?? ""
        return ProposalDraft(
            payload: .changeSpec(oldText: document.content, newText: text), target: .document(document.id),
            reason: "Asked for in a comment on the spec: \"\(firstLine.prefix(200))\"",
            source: ProposalSource(kind: .comment, value: comment.url ?? comment.id.rawValue),
            targetUpdatedAt: document.updatedAt)
    }

    /// The `createIssue` proposal for the change that a comment on a done or
    /// closed issue asked for, in the issue's team and project, related to
    /// it. Nil when the answer has no description for it.
    static func issueDraft(_ answer: CommentAnswer, issue: IssueComments, comment: LinearThreadComment) -> ProposalDraft? {
        guard let description = answer.revision, let teamId = issue.teamId else { return nil }
        let firstLine = comment.body.split(separator: "\n").first.map(String.init) ?? ""
        let title = answer.title ?? "Follow-up to \(issue.identifier): \(firstLine.prefix(80))"
        return ProposalDraft(
            payload: .createIssue(teamId: teamId, projectId: issue.projectId, title: title, description: description, relatedIssueId: issue.id),
            target: .team(teamId),
            reason: "Asked for in a comment on \(issue.identifier), which is \(issue.stateType == .completed ? "done" : "closed"): \"\(firstLine.prefix(200))\"",
            source: ProposalSource(kind: .comment, value: comment.url ?? comment.id.rawValue, issue: LinearIssue.Identifier(rawValue: issue.identifier)))
    }

    /// Where the comment is, for the log.
    var location: String {
        switch subject {
        case .proposal(let proposal, _):
            "\(proposal.kind.rawValue) \(proposal.id) on \(proposal.post?.issueIdentifier ?? proposal.post?.issueId.rawValue ?? "?")"
        case .spec: "the spec document"
        case .issue(let issue, _): issue.identifier
        }
    }

    /// What the reply is made on.
    var target: CommentTarget? {
        switch subject {
        case .proposal(_, let issueId): .issue(issueId)
        case .spec(let document, _): document.documentContentId.map { .document(contentId: $0) }
        case .issue(let issue, _): .issue(issue.id)
        }
    }
}

/// What a session answers: what the comment is, the reply, and the new text
/// of the proposal, the spec or the issue's description when the comment
/// asks for a change, or the description of a new issue with its title.
struct CommentAnswer: Codable, Sendable, Equatable {
    /// What a comment is.
    enum Kind: String, Codable, Sendable {
        case question
        /// A request for a change.
        case change
        /// A note that needs nothing, such as "thanks".
        case note
    }

    var kind: Kind?
    var answer: String
    var revision: String?
    var title: String?

    init(kind: Kind? = nil, answer: String, revision: String? = nil, title: String? = nil) {
        self.kind = kind
        self.answer = answer
        self.revision = revision
        self.title = title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind)
        // Only a comment of a known kind may have no answer.
        answer = kind == nil
            ? try container.decode(String.self, forKey: .answer)
            : try container.decodeIfPresent(String.self, forKey: .answer) ?? ""
        revision = try container.decodeIfPresent(String.self, forKey: .revision)
        title = try container.decodeIfPresent(String.self, forKey: .title)
    }

    /// Whether superlinear replies: not to a note, nor to a request that
    /// has no answer, as one handed to an agent.
    var replies: Bool { kind != .note && !answer.isEmpty }

    /// The answer in a session's output: a JSON object, alone, in a code
    /// block, or after other text.
    static func parse(_ output: String) throws -> CommentAnswer {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = [text]
        if let fenced = text.firstMatch(of: /```(?:json)?\s*\n([\s\S]*?)\n\s*```/) { candidates.append(String(fenced.output.1)) }
        if let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close {
            candidates.append(String(text[open...close]))
        }
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8), var answer = try? JSONDecoder().decode(CommentAnswer.self, from: data) else {
                continue
            }
            if answer.revision?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { answer.revision = nil }
            if answer.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { answer.title = nil }
            answer.answer = CommentResponder.bare(answer.answer)
            // A note needs no reply, and a request may go to an agent without one.
            guard !answer.answer.isEmpty || [.note, .change].contains(answer.kind) else { throw CommentAnswerError.emptyAnswer }
            return answer
        }
        throw CommentAnswerError.noAnswer(String(text.suffix(500)))
    }
}

enum CommentAnswerError: Error, CustomStringConvertible {
    case noAnswer(String)
    case emptyAnswer
    case noTarget

    var description: String {
        switch self {
        case .noAnswer(let tail): "The session's output has no answer as JSON; it ends: \(tail)"
        case .emptyAnswer: "The session's answer is empty"
        case .noTarget: "Linear gave no document content to reply on"
        }
    }
}

/// A change the owner asked for in a comment, made to a pending proposal.
enum ProposalRevision {
    /// What the revision replaces, for the prompt, or nil when the kind has
    /// no text to change.
    static func meaning(_ kind: ProposalKind) -> String? {
        switch kind {
        case .createIssue: "the whole new description of the proposed issue"
        case .editIssue: "the whole new text of the issue's managed block"
        case .changeSpec: "the whole new text of the spec"
        case .postProjectUpdate: "the whole new body of the project update"
        case .closeIssue, .addRelation, .promoteIssue: nil
        }
    }

    /// The proposal with `text` as its new text, or nil when its kind has
    /// none, or the text is the same.
    static func applying(_ text: String, to proposal: Proposal) -> Proposal? {
        var revised = proposal
        switch proposal.payload {
        case .createIssue(let teamId, let projectId, let title, let description, let relatedIssueId):
            guard text != description else { return nil }
            revised.payload = .createIssue(
                teamId: teamId, projectId: projectId, title: title, description: text, relatedIssueId: relatedIssueId)
        case .editIssue(let old, let new):
            guard text != new else { return nil }
            revised.payload = .editIssue(oldText: old, newText: text)
        case .changeSpec(let old, let new):
            guard text != new else { return nil }
            revised.payload = .changeSpec(oldText: old, newText: text)
        case .postProjectUpdate(let body, let overviewIssueId):
            guard text != body else { return nil }
            revised.payload = .postProjectUpdate(body: text, overviewIssueId: overviewIssueId)
        case .closeIssue, .addRelation, .promoteIssue:
            return nil
        }
        return revised
    }
}

/// The prompts of the read-only sessions that answer the owner's comments.
enum CommentAnswerPrompt {
    private static let preamble = """
        You answer a question or a request that the owner of a Linear workspace wrote in a comment. \
        superlinear, the automation that runs you, posts your answer as a reply in the comment's thread.

        You only read. Do not edit or create files, do not commit or push, do not open pull requests, and \
        do not write to Linear or GitHub. The current directory is the repository's default-branch \
        worktree: read the code and its history there when the answer depends on them. \
        \(LinearKey.promptLine)
        """

    /// How many of the issues a comment names its prompt shows.
    static let maxNamedIssues = 10

    /// The identifiers of the workspace's issues that the comment names, and
    /// for a proposal, that the proposal names, in the order they appear:
    /// those of the teams with `teamKeys` only, without the issue the comment
    /// is on, and at most `maxNamedIssues`.
    static func namedIdentifiers(_ question: CommentQuestion, teamKeys: Set<LinearTeam.Key>) -> [LinearIssue.Identifier] {
        var text = question.comment.comment.body
        var own: LinearIssue.Identifier?
        if case .proposal(let proposal, _) = question.subject {
            text += "\n" + describe(proposal)
            own = proposal.post?.issueIdentifier.map { LinearIssue.Identifier(rawValue: $0) }
        }
        if case .issue(let issue, _) = question.subject { own = LinearIssue.Identifier(rawValue: issue.identifier) }
        var seen: Set<LinearIssue.Identifier> = []
        var identifiers: [LinearIssue.Identifier] = []
        for match in text.matches(of: /\b([A-Z][A-Z0-9]*)-[0-9]+\b/) {
            let identifier = LinearIssue.Identifier(rawValue: String(match.output.0))
            guard teamKeys.contains(LinearTeam.Key(rawValue: String(match.output.1))), identifier != own,
                  seen.insert(identifier).inserted
            else { continue }
            identifiers.append(identifier)
            if identifiers.count == maxNamedIssues { break }
        }
        return identifiers
    }

    static func render(_ question: CommentQuestion, openIssues: [String], namedIssues: [PlanningIssue]) -> String {
        var sections = [preamble]
        let revision: String?
        switch question.subject {
        case .proposal(let proposal, _):
            sections.append("The comment is about this proposal, which waits for the owner's answer:\n\n" + describe(proposal))
            revision = ProposalRevision.meaning(proposal.kind)
        case .spec(let document, let url):
            var spec = "The comment is on the workspace's spec document, which superlinear checks proposals against"
            if let url { spec += " (\(url))" }
            sections.append(spec + ". Its text:\n\n" + fenced(document.content))
            if !openIssues.isEmpty {
                sections.append("The open issues of the watched teams:\n\n" + openIssues.map { "- \($0)" }.joined(separator: "\n"))
            }
            revision = "the whole new text of the spec document"
        case .issue(let issue, let situation):
            sections.append("The comment is on this issue. " + describe(situation) + "\n\n" + describe(issue))
            revision = nil
        }
        if !namedIssues.isEmpty {
            sections.append("The Linear issues that the comment names, as they stand now:\n\n"
                + namedIssues.map(describe).joined(separator: "\n\n"))
        }
        let earlier = question.thread.filter { $0.id != question.comment.comment.id }
        if !earlier.isEmpty {
            sections.append("The comments before it, oldest first. Those that start with \"\(CommentMarker.line)\" are superlinear's:\n\n"
                + renderedComments(earlier.map { PromptComment($0) }))
        }
        sections.append("The owner's comment to answer:\n\n"
            + renderedComments([PromptComment(question.comment.comment, previousBody: question.comment.previousBody)]))
        var reply = """
            First decide what the comment is: "question", a question; "change", a request for a change; or \
            "note", a note that needs nothing, such as "thanks" or "FYI", which gets no reply. Answer in \
            Markdown, plainly and briefly, to the owner. When the answer is an estimate, say what it rests on. \
            superlinear adds the line "\(CommentMarker.line)" at the start of the reply, and its own note on what \
            became of a change at the end: write neither. Reply with only a JSON object, and nothing after it:

            {"kind": "question", "answer": "<your answer>", "revision": null}
            """
        switch question.subject {
        case .issue(_, let situation):
            reply += "\n\n" + instructions(situation)
        case .proposal where revision == nil:
            reply += "\n\nThis kind of proposal has no text to change: keep \"revision\" null. When the comment asks for a different change, say that the owner can reject this proposal with 👎."
        case .proposal:
            reply += "\n\nWhen the comment asks for a change to the proposal, set \"revision\" to \(revision!), with the change made, and say in your answer what you changed. The proposal still waits for the owner's answer. Otherwise keep \"revision\" null."
        case .spec:
            reply += "\n\nWhen the comment asks for a change to the spec, set \"revision\" to \(revision!), with the change made; superlinear proposes it for the owner to accept, and never changes the document itself. Say in your answer what the change is. Otherwise keep \"revision\" null."
        }
        sections.append(reply)
        return sections.joined(separator: "\n\n")
    }

    /// Where the issue stands, for the prompt.
    static func describe(_ situation: IssueSituation) -> String {
        switch situation {
        case .open: "No agent of superlinear's works on it."
        case .running: "An agent of superlinear's works on it now."
        case .pullRequest: "superlinear's agent opened a pull request for it, which waits for review."
        case .agentEnded: "superlinear's agent worked on it, and ended without a pull request."
        case .done: "It is done."
        case .closed: "It was canceled, or closed as a duplicate."
        }
    }

    /// What to do with a request for a change, by where the issue stands.
    static func instructions(_ situation: IssueSituation) -> String {
        switch situation {
        case .open:
            "When the comment asks for a change to the issue, set \"kind\" to \"change\" and \"revision\" to the whole new description of the issue, with the change made, and say in your answer what you changed. Otherwise keep \"revision\" null."
        case .running, .pullRequest, .agentEnded:
            "For a question, answer with what is known now: read the issue's branch, its pull request and its comments. A request for a change is not yours to make: superlinear gives it to the next agent on the issue, so set \"kind\" to \"change\", leave \"answer\" empty, and keep \"revision\" null."
        case .done, .closed:
            "For a question, answer it; when the issue is done, say where it was done, such as its pull request, with the link; when it was closed, say why, or the issue it duplicates. When the comment asks for a change, set \"kind\" to \"change\", \"title\" to the title of a new issue for it, and \"revision\" to that issue's description; superlinear proposes the new issue, and the owner decides. Say in your answer what the new issue is for."
        }
    }

    /// The issue a comment is on, as the owner sees it in Linear.
    static func describe(_ issue: IssueComments) -> String {
        var lines = ["- \(issue.identifier): \(issue.title)", "  - State: \(issue.stateName ?? issue.stateType.rawValue)"]
        if let url = issue.url { lines.append("  - Link: \(url)") }
        if !issue.labels.isEmpty { lines.append("  - Labels: " + issue.labels.joined(separator: ", ")) }
        let description = issue.description.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(description.isEmpty ? "  - No description" : "  - Description:\n\n" + fenced(description))
        return lines.joined(separator: "\n")
    }

    /// The proposal as the owner sees it in Linear, and where it came from.
    static func describe(_ proposal: Proposal) -> String {
        var lines = ["- Kind: \(proposal.kind.rawValue)", "- What: superlinear proposes to \(ProposalForm.action(proposal, related: nil))"]
        if let post = proposal.post { lines.append("- In Linear: \(post.issueIdentifier ?? post.issueId.rawValue)" + (post.url.map { ", \($0)" } ?? "")) }
        lines.append("- Reason: \(proposal.reason)")
        lines.append("- \(proposal.source.line)")
        if let note = proposal.reviewNote { lines.append("- Note: \(note)") }
        switch proposal.payload {
        case .createIssue(_, _, let title, let description, _):
            lines.append("\nThe proposed issue's title: \(title)\n\nIts description:\n\n" + fenced(description))
        case .postProjectUpdate(let body, _):
            lines.append("\nThe update:\n\n" + fenced(body))
        default:
            if let diff = ProposalForm.diff(proposal.payload) { lines.append("\nThe change:\n\n" + diff.joined(separator: "\n")) }
        }
        return lines.joined(separator: "\n")
    }

    /// A named issue: its title, state, labels, relations and description.
    static func describe(_ issue: PlanningIssue) -> String {
        var lines = ["- \(issue.identifier): \(issue.title)", "  - State: \(issue.stateName)"]
        if !issue.labels.isEmpty { lines.append("  - Labels: " + issue.labels.map(\.rawValue).joined(separator: ", ")) }
        if !issue.relations.isEmpty { lines.append("  - Relations: " + issue.relations.map(\.rendered).joined(separator: ", ")) }
        let description = issue.description.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(description.isEmpty ? "  - No description" : "  - Description:\n\n" + fenced(description))
        return lines.joined(separator: "\n")
    }

    private static func fenced(_ text: String) -> String {
        "````markdown\n\(text)\n````"
    }
}

/// A session that answered a comment, kept for its token use.
struct CommentAnswerRecord: Codable, Sendable, Equatable {
    var sessionId: ClaudeSession.ID
    var startedAt: Date
    var endedAt: Date
    /// Where the comment was, such as a proposal on an issue.
    var location: String
    var usage: AgentUsage?
    /// Why it failed, if it did.
    var error: String?
}

/// Runs the read-only Claude sessions that answer comments, and waits for
/// each. A session the daemon's restart cuts short leaves its comment
/// unhandled, so the next daemon answers it.
struct CommentSessionRunner: Sendable {
    /// Reading the code, its history, its pull requests and the workspace's
    /// Linear issues; no writes.
    static let allowedTools =
        "Read,Grep,Glob,Bash(git log:*),Bash(git show:*),Bash(git diff:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh run view:*),"
        + LinearKey.readTools
    /// How long a session may run before it is stopped.
    static let timeout: TimeInterval = 20 * 60

    let home: String
    let environment: [String: String]

    init(home: String = Paths.home, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = home
        self.environment = environment
    }

    var runsDirectory: String { "\(home)/.local/share/superlinear/runs" }
    var logsDirectory: String { "\(home)/.local/share/superlinear/logs" }

    /// The sessions' output for a workspace, appended across sessions.
    func log(workspace: String) -> String { "\(logsDirectory)/comments-\(Transcripts.encoded(workspace)).log" }

    static func claudeArguments(sessionId: ClaudeSession.ID, model: PlanningModel) -> [String] {
        ["claude", "-p", "--session-id", sessionId.rawValue] + model.arguments + ["--allowedTools", allowedTools]
    }

    /// The environment a session launches with: the daemon's, with the
    /// workspace's Linear key `apiKey`.
    func sessionEnvironment(apiKey: String) -> [String: String] {
        LinearKey.environment(environment, apiKey: apiKey)
    }

    /// What a session printed, and its exit status.
    struct Session: Sendable, Equatable {
        var output: String
        var status: Int32?
    }

    /// Runs a session on `model` in `worktree` with `prompt`, and returns once it ends.
    func run(
        prompt: String, sessionId: ClaudeSession.ID, model: PlanningModel, worktree: String, workspace: String, apiKey: String
    ) async throws -> Session {
        let fm = FileManager.default
        try fm.createDirectory(atPath: runsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: logsDirectory, withIntermediateDirectories: true)
        let promptFile = "\(runsDirectory)/comment-\(sessionId).prompt"
        let outputFile = "\(runsDirectory)/comment-\(sessionId).output"
        defer {
            try? fm.removeItem(atPath: promptFile)
            try? fm.removeItem(atPath: outputFile)
        }
        try prompt.write(toFile: promptFile, atomically: true, encoding: .utf8)
        fm.createFile(atPath: outputFile, contents: nil)
        let logPath = log(workspace: workspace)
        if !fm.fileExists(atPath: logPath) { fm.createFile(atPath: logPath, contents: nil) }
        guard let input = FileHandle(forReadingAtPath: promptFile), let output = FileHandle(forWritingAtPath: outputFile),
              let errors = FileHandle(forWritingAtPath: logPath)
        else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: runsDirectory]) }
        errors.seekToEndOfFile()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\"$@\"", "sh"] + Self.claudeArguments(sessionId: sessionId, model: model)
        process.currentDirectoryURL = URL(fileURLWithPath: worktree)
        process.environment = sessionEnvironment(apiKey: apiKey)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let status: Int32? = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationReason == .exit ? process.terminationStatus : nil)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
                return
            }
            let timeout = Self.timeout
            Task.detached {
                try? await Task.sleep(for: .seconds(timeout))
                if process.isRunning { process.terminate() }
            }
        }
        try? input.close()
        try? output.close()
        let text = (try? String(contentsOfFile: outputFile, encoding: .utf8)) ?? ""
        errors.write(Data("[\(ProposalForm.time(Date()))] session \(sessionId) exited \(status.map(String.init) ?? "without a status"):\n\(text)\n".utf8))
        try? errors.close()
        return Session(output: text, status: status)
    }
}

/// Writes a session's answer in Linear: the reply in the comment's thread,
/// and for a proposal, a change the owner asked for and the proposed label.
struct CommentResponder: Sendable {
    let linear: any LinearWriting
    let specDocumentURL: String?

    struct Answered: Sendable, Equatable {
        /// The proposal with the owner's change, when the answer made one.
        var revised: Proposal?
        var reply: CreatedComment
    }

    /// Answers a comment on `proposal`, as it stands now: makes the change
    /// the answer brings, in the proposed issue or the proposal's comment,
    /// replies, and keeps the label `superlinear: proposed` on the issue, as
    /// a reply written with the owner's key reaches no inbox.
    func answer(_ question: CommentQuestion, about proposal: Proposal, with answer: CommentAnswer, now: Date) async throws -> Answered {
        guard case .proposal(_, let issueId) = question.subject else { throw CommentAnswerError.noTarget }
        var text = answer.answer
        var revised: Proposal?
        if let revision = answer.revision, let changed = ProposalRevision.applying(revision, to: proposal), let post = proposal.post {
            if let commentId = post.commentId {
                _ = try await linear.updateComment(
                    id: commentId, body: ProposalForm.commentBody(changed, related: nil, now: now, superseded: false))
            } else {
                var link: String?
                if case .document(_, _) = changed.target { link = specDocumentURL }
                _ = try await linear.updateIssueDescription(
                    id: post.issueId, description: ProposalForm.issueDescription(changed, specLink: link))
            }
            revised = changed
            text += "\n\n" + Self.revisedNote
        }
        let reply = try await linear.createReply(
            on: .issue(issueId), parentId: question.comment.comment.rootId, body: CommentMarker.reply(text))
        let issue = try await linear.editableIssue(id: issueId)
        if !issue.labels.contains(where: { $0.caseInsensitiveCompare(ProposalEngine.proposedLabel) == .orderedSame }) {
            let labelId = try await linear.labelId(named: ProposalEngine.proposedLabel, teamId: issue.teamId)
            _ = try await linear.addLabel(issueId: issueId, labelId: labelId)
        }
        return Answered(revised: revised, reply: reply)
    }

    /// Answers a comment on an issue outside any proposal, as it stands now.
    /// A request on an open issue changes its description, unless the issue
    /// is hands off; one on a done or closed issue was proposed as a new
    /// issue, `proposal`, which the reply links. Replies, and puts the label
    /// `superlinear: replied` on the issue, as a reply written with the
    /// owner's key reaches no inbox.
    func answer(
        _ question: CommentQuestion, situation: IssueSituation, with answer: CommentAnswer, proposal: Proposal?
    ) async throws -> CreatedComment {
        guard case .issue(let asked, _) = question.subject else { throw CommentAnswerError.noTarget }
        let issue = try await linear.editableIssue(id: asked.id)
        let handsOff = Self.has(ProposalEngine.handsOffLabel, issue.labels)
        var notes: [String] = []
        if answer.kind == .change, situation == .open, let revision = answer.revision, revision != issue.description {
            if handsOff {
                notes.append(Self.handsOffNote)
            } else {
                _ = try await linear.updateIssueDescription(id: issue.id, description: revision)
                notes.append(Self.describedNote)
            }
        }
        if answer.kind == .change, situation.requestProposesIssue {
            notes.append(Self.issueProposalNote(proposal))
        }
        let text = ([answer.answer] + notes).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let reply = try await linear.createReply(
            on: .issue(issue.id), parentId: question.comment.comment.rootId, body: CommentMarker.reply(text))
        if !handsOff, !Self.has(ProposalEngine.proposedLabel, issue.labels), !Self.has(Self.repliedLabel, issue.labels) {
            let labelId = try await linear.labelId(named: Self.repliedLabel, teamId: issue.teamId)
            _ = try await linear.addLabel(issueId: issue.id, labelId: labelId)
        }
        return reply
    }

    private static func has(_ label: String, _ labels: [String]) -> Bool {
        labels.contains { $0.caseInsensitiveCompare(label) == .orderedSame }
    }

    /// The label on an issue that superlinear replied on, outside any
    /// proposal, so that it shows in the proposals view.
    static let repliedLabel = "superlinear: replied"

    /// The note on a reply whose request changed the issue's description.
    static let describedNote = "superlinear changed the issue's description as asked."
    /// The note on a reply whose request was not made, as the issue is hands off.
    static let handsOffNote = "superlinear did not change the issue: it has the label \"\(ProposalEngine.handsOffLabel)\"."
    /// The start of the note on a reply whose request became a new issue.
    static let issueProposalNotePrefix = "superlinear proposed a new issue for this: "

    /// The note on a reply to a request on a done or closed issue.
    static func issueProposalNote(_ proposal: Proposal?) -> String {
        guard let proposal else { return noChangeNote }
        if let post = proposal.post {
            let link = post.url.map { "[\(post.issueIdentifier ?? "the proposal")](\($0))" } ?? (post.issueIdentifier ?? "an issue")
            return issueProposalNotePrefix + link + "."
        }
        return issueProposalNotePrefix + (proposal.status == .applied ? "created at once, as its trust level is auto." : "it waits for review.")
    }

    /// The emoji of the reaction on each comment queued, which tells the
    /// owner that superlinear saw it.
    static let seenEmoji = "eyes"

    /// Adds the 👀 reaction to the comment, unless `ledger` has it as given
    /// one already. Returns the ledger with the reaction recorded, or nil
    /// when there was nothing to do.
    static func markSeen(_ question: CommentQuestion, ledger: CommentLedger?, linear: any LinearWriting) async throws -> CommentLedger? {
        let id = question.comment.comment.id
        guard ledger?.reacted.contains(id) != true else { return nil }
        _ = try await linear.addReaction(commentId: id, emoji: seenEmoji)
        var seen = ledger ?? CommentLedger(since: question.since)
        seen.reacted.insert(id)
        return seen
    }

    /// Replies in the comment's thread with `text`.
    func reply(to question: CommentQuestion, text: String) async throws -> CreatedComment {
        guard let target = question.target else { throw CommentAnswerError.noTarget }
        return try await linear.createReply(on: target, parentId: question.comment.comment.rootId, body: CommentMarker.reply(text))
    }

    /// The reply to a comment on the spec, with what became of a change it
    /// asked for: the proposal's link, or why there is none.
    static func specReply(_ answer: String, proposal: Proposal?, asked: Bool) -> String {
        guard asked else { return answer }
        guard let proposal else {
            return answer + "\n\n" + noChangeNote
        }
        let link = proposal.post.map { post in
            post.url.map { "[\(post.issueIdentifier ?? "the proposal")](\($0))" } ?? (post.issueIdentifier ?? "an issue")
        } ?? "a proposal"
        return answer + "\n\n\(proposedNotePrefix)\(link)\(proposedNoteSuffix)"
    }

    /// The note on a reply whose answer changed the proposal.
    static let revisedNote = "superlinear changed the proposal as asked. It still waits for your answer."
    /// The note on a spec reply whose change was not proposed.
    static let noChangeNote = "superlinear proposed no change: the same change is pending already, or you rejected it."
    /// The start of the note on a spec reply whose change was proposed.
    static let proposedNotePrefix = "superlinear proposed this change as "
    /// The end of the note on a spec reply whose change was proposed.
    static let proposedNoteSuffix = ", in Triage. The document changes only when you accept it."

    /// A session's answer without the marker line at its start and the
    /// notes at its end that superlinear adds to the reply itself, which a
    /// session copies from superlinear's earlier replies in the thread.
    ///
    /// One pass over the answer's lines, from each end: it removes only lines
    /// that are blank, the marker, or a whole note, and stops at the first
    /// other line, so a quote of them in the answer's text stays.
    static func bare(_ answer: String) -> String {
        let lines = answer.components(separatedBy: "\n")
        let kept = lines
            .drop { isBlank($0) || $0.trimmingCharacters(in: .whitespaces) == CommentMarker.line }
            .reversed()
            .drop { isBlank($0) || isNote($0) }
            .reversed()
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Whether the line is, in full, a note that superlinear adds to a reply.
    private static func isNote(_ line: String) -> Bool {
        let line = line.trimmingCharacters(in: .whitespaces)
        return line == revisedNote || line == noChangeNote || line == describedNote || line == handsOffNote
            || line.hasPrefix(issueProposalNotePrefix)
            || (line.hasPrefix(proposedNotePrefix) && line.hasSuffix(proposedNoteSuffix))
    }
}
