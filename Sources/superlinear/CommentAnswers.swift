import Foundation

/// A question or request from the owner that a read-only Claude session
/// answers: on a pending proposal, or on the spec document.
struct CommentQuestion: Sendable, Equatable {
    enum Subject: Sendable, Equatable {
        /// A proposal waiting in Linear, and the issue the comment is on.
        case proposal(Proposal, issueId: LinearIssue.ID)
        /// The spec document, and its URL when known.
        case spec(DocumentComments, url: String?)
    }

    var subject: Subject
    var comment: FreshComment
    /// The comments before it that it may refer to, oldest first, with it.
    var thread: [LinearThreadComment]
    /// The key of the ledger that records it handled.
    var key: String
    /// The ledger's baseline, should it have none yet.
    var since: Date

    init(subject: Subject, comment: FreshComment, thread: [LinearThreadComment], key: String, since: Date) {
        self.subject = subject
        self.comment = comment
        self.thread = thread
        self.key = key
        self.since = since
    }

    init(_ answer: CommentTriage.Answer, since: Date) {
        self.init(
            subject: .proposal(answer.proposal, issueId: answer.issueId), comment: answer.comment, thread: answer.thread,
            key: answer.issueId.rawValue, since: since)
    }

    /// The questions in the owner's fresh comments on the spec document,
    /// each with its thread.
    static func spec(_ document: DocumentComments, url: String?, ledger: CommentLedger, viewer: LinearUser.ID) -> [CommentQuestion] {
        ledger.fresh(document.comments, viewer: viewer).map { fresh in
            let thread = document.comments.filter {
                $0.rootId == fresh.comment.rootId && ($0.createdAt < fresh.comment.createdAt || $0.id == fresh.comment.id)
            }
            return CommentQuestion(
                subject: .spec(document, url: url), comment: fresh, thread: thread, key: CommentTriage.documentKey(document.id),
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

    /// Where the comment is, for the log.
    var location: String {
        switch subject {
        case .proposal(let proposal, _):
            "\(proposal.kind.rawValue) \(proposal.id) on \(proposal.post?.issueIdentifier ?? proposal.post?.issueId.rawValue ?? "?")"
        case .spec: "the spec document"
        }
    }

    /// What the reply is made on.
    var target: CommentTarget? {
        switch subject {
        case .proposal(_, let issueId): .issue(issueId)
        case .spec(let document, _): document.documentContentId.map { .document(contentId: $0) }
        }
    }
}

/// What a session answers: the reply, and the new text of the proposal or
/// the spec when the comment asks for a change.
struct CommentAnswer: Codable, Sendable, Equatable {
    var answer: String
    var revision: String?

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
            guard !answer.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CommentAnswerError.emptyAnswer }
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
        worktree: read the code and its history there when the answer depends on them.
        """

    static func render(_ question: CommentQuestion, openIssues: [String] = []) -> String {
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
        }
        let earlier = question.thread.filter { $0.id != question.comment.comment.id }
        if !earlier.isEmpty {
            sections.append("The comments before it, oldest first. Those that start with \"\(CommentMarker.line)\" are superlinear's:\n\n"
                + renderedComments(earlier.map { PromptComment($0) }))
        }
        sections.append("The owner's comment to answer:\n\n"
            + renderedComments([PromptComment(question.comment.comment, previousBody: question.comment.previousBody)]))
        var reply = """
            Answer in Markdown, plainly and briefly, to the owner. When the answer is an estimate, say what it \
            rests on. Reply with only a JSON object, and nothing after it:

            {"answer": "<your answer>", "revision": null}
            """
        switch question.subject {
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
    /// Reading the code, its history and its pull requests; no writes.
    static let allowedTools =
        "Read,Grep,Glob,Bash(git log:*),Bash(git show:*),Bash(git diff:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh run view:*)"
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

    static func claudeArguments(sessionId: ClaudeSession.ID) -> [String] {
        ["claude", "-p", "--session-id", sessionId.rawValue, "--allowedTools", allowedTools]
    }

    /// What a session printed, and its exit status.
    struct Session: Sendable, Equatable {
        var output: String
        var status: Int32?
    }

    /// Runs a session in `worktree` with `prompt`, and returns once it ends.
    func run(prompt: String, sessionId: ClaudeSession.ID, worktree: String, workspace: String) async throws -> Session {
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
        process.arguments = ["-c", "\"$@\"", "sh"] + Self.claudeArguments(sessionId: sessionId)
        process.currentDirectoryURL = URL(fileURLWithPath: worktree)
        process.environment = environment
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
            text += "\n\nsuperlinear changed the proposal as asked. It still waits for your answer."
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
            return answer + "\n\nsuperlinear proposed no change: the same change is pending already, or you rejected it."
        }
        let link = proposal.post.map { post in
            post.url.map { "[\(post.issueIdentifier ?? "the proposal")](\($0))" } ?? (post.issueIdentifier ?? "an issue")
        } ?? "a proposal"
        return answer + "\n\nsuperlinear proposed this change as \(link), in Triage. The document changes only when you accept it."
    }
}
