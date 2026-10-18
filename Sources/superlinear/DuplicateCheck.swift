import Foundation

/// An open issue or a proposal that may be the same work as a proposed new
/// issue, as the proposed issue lists it for the owner.
struct PossibleDuplicate: Codable, Sendable, Equatable {
    /// The issue's identifier, such as `SPL-9`, or `proposal 1a2b3c4d`.
    var name: String
    var title: String
    var url: String?
    /// What it is, when it is not an open issue, such as "rejected proposal".
    var note: String?

    /// The line that lists it in the comment on the proposed issue.
    var line: String {
        let name = url.map { "[\(self.name)](\($0))" } ?? self.name
        return "- \(name): \(title)" + (note.map { " (\($0))" } ?? "")
    }
}

/// What a proposed new issue is compared with: an open issue that Linear's
/// search found, or a proposed issue already in Linear; or a proposal not
/// in Linear, pending or rejected.
enum DuplicateCandidate: Sendable, Equatable {
    case issue(IssueMatch)
    case proposal(Proposal)

    /// How the agent names it.
    var key: String {
        switch self {
        case .issue(let match): match.identifier
        case .proposal(let proposal): "proposal-\(proposal.id.rawValue.prefix(8))"
        }
    }

    var title: String {
        switch self {
        case .issue(let match): match.title
        case .proposal(let proposal): ProposalForm.issueTitle(proposal)
        }
    }

    var description: String {
        switch self {
        case .issue(let match): match.description
        case .proposal(let proposal):
            if case .createIssue(_, _, _, let description, _) = proposal.payload { description } else { "" }
        }
    }

    var possible: PossibleDuplicate {
        switch self {
        case .issue(let match):
            PossibleDuplicate(name: match.identifier, title: match.title, url: match.url)
        case .proposal(let proposal):
            PossibleDuplicate(
                name: "proposal \(proposal.id.rawValue.prefix(8))", title: title, url: nil,
                note: proposal.status == .rejected ? "rejected proposal" : "pending proposal, not in Linear yet")
        }
    }

    /// The candidates for a new issue in `teamId`: the proposed issues in
    /// that team that are pending or were rejected, newest first, then the
    /// open issues that Linear's search found for its title. A proposed
    /// issue in Linear is compared as the issue it is.
    static func gather(teamId: LinearTeam.ID, matches: [IssueMatch], existing: [Proposal]) -> [DuplicateCandidate] {
        var candidates: [DuplicateCandidate] = []
        var issueIds: Set<LinearIssue.ID> = []
        let proposals = existing
            .filter { proposal in
                guard case .createIssue(let team, _, _, _, _) = proposal.payload else { return false }
                return team == teamId && [.pending, .rejected].contains(proposal.status)
            }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(DuplicateQuestion.maxProposals)
        for proposal in proposals {
            if proposal.status == .pending, let post = proposal.post, post.isIssue {
                issueIds.insert(post.issueId)
                candidates.append(.issue(IssueMatch(
                    id: post.issueId, identifier: post.issueIdentifier ?? post.issueId.rawValue,
                    title: ProposalForm.issueTitle(proposal), description: DuplicateCandidate.proposal(proposal).description,
                    url: post.url)))
            } else if proposal.post == nil || proposal.status == .rejected {
                candidates.append(.proposal(proposal))
            }
        }
        for match in matches.prefix(DuplicateQuestion.maxIssues) where issueIds.insert(match.id).inserted {
            candidates.append(.issue(match))
        }
        return candidates
    }
}

/// Whether a proposed new issue is the same work as one of its candidates.
struct DuplicateQuestion: Sendable, Equatable {
    /// The most open issues from Linear's search that the agent is given.
    static let maxIssues = 10
    /// The most proposals that the agent is given.
    static let maxProposals = 20
    /// The most characters of a description that the agent is given.
    static let maxDescription = 4000

    var title: String
    var description: String
    var candidates: [DuplicateCandidate]
}

/// The agent's answer.
enum DuplicateVerdict: Sendable, Equatable {
    /// It is the same work as none of the candidates.
    case distinct
    /// It is the same work as the candidate with `key`. `added` is what the
    /// new issue says that the candidate does not, in Markdown, or empty.
    case duplicate(key: String, added: String)
    /// It may be the same work as these candidates; the owner decides.
    case possible(keys: [String])
}

/// Asks whether a new issue is the same work as another. `ClaudeDuplicateJudge`
/// asks Claude; tests stand in for it.
protocol DuplicateJudging: Sendable {
    func judge(_ question: DuplicateQuestion) async throws -> DuplicateVerdict
}

enum DuplicateCheckError: Error, CustomStringConvertible, Equatable {
    case claudeFailed(String)
    case unreadable(String)

    var description: String {
        switch self {
        case .claudeFailed(let reason): "Claude could not check for duplicates: \(reason)"
        case .unreadable(let output): "Claude's answer about duplicates could not be read: \(output)"
        }
    }
}

/// The prompt that asks for a `DuplicateVerdict`, and how its answer is read.
enum DuplicatePrompt {
    static func render(_ question: DuplicateQuestion) -> String {
        var lines = [
            "You check whether a proposed new Linear issue is the same work as an open issue or an earlier proposal.",
            "Two issues are the same work when doing one would do the other, even when their words differ:",
            "\"Retry failed syncs\" and \"Make sync robust to network errors\" are the same work.",
            "Issues about the same area that ask for different changes are not.",
            "",
            "Answer with one JSON object and nothing else:",
            "",
            #"{"verdict": "duplicate" | "possible" | "distinct", "of": ["<key>", ...], "added": "<markdown>"}"#,
            "",
            "- `duplicate`: it is the same work as exactly one candidate, and you are sure. `of` has that candidate's key.",
            "  `added` has what the new issue says that the candidate does not, such as details, evidence or acceptance criteria,",
            "  as Markdown to add to the candidate's description, or \"\" when it adds nothing. Do not repeat what the candidate says.",
            "- `possible`: it may be the same work as one or more candidates, but you are not sure. `of` has their keys.",
            "- `distinct`: it is the same work as none of them. `of` is empty.",
            "",
            "## The new issue",
            "",
            "Title: \(question.title)",
            "",
            truncated(question.description),
            "",
            "## The candidates",
        ]
        for candidate in question.candidates {
            lines += ["", "### \(candidate.key): \(candidate.title)"]
            if case .proposal(let proposal) = candidate {
                lines.append(proposal.status == .rejected ? "(A proposal the owner rejected.)" : "(A pending proposal.)")
            }
            lines += ["", truncated(candidate.description)]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func truncated(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "(No description.)" }
        guard text.count > DuplicateQuestion.maxDescription else { return text }
        return String(text.prefix(DuplicateQuestion.maxDescription)) + "\n(Cut short.)"
    }

    private struct Answer: Decodable {
        var verdict: String
        var of: [String]?
        var added: String?
    }

    /// The verdict in `output`, the first JSON object in it. Keys that are
    /// not candidates are dropped; a duplicate of none is a possible one of
    /// none, which is distinct.
    static func verdict(from output: String, keys: [String]) throws -> DuplicateVerdict {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
              let answer = try? JSONDecoder().decode(Answer.self, from: Data(output[start...end].utf8))
        else { throw DuplicateCheckError.unreadable(output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let of = (answer.of ?? []).filter { keys.contains($0) }
        switch answer.verdict {
        case "duplicate" where of.count == 1:
            return .duplicate(key: of[0], added: (answer.added ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        case "duplicate", "possible":
            return of.isEmpty ? .distinct : .possible(keys: of)
        case "distinct":
            return .distinct
        default:
            throw DuplicateCheckError.unreadable(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// Asks a short headless Claude session, with no tools, for the verdict.
struct ClaudeDuplicateJudge: DuplicateJudging {
    static let arguments = ["claude", "-p", "--tools", "", "--output-format", "text"]
    /// How long a session may take before it is stopped.
    static let timeout: TimeInterval = 5 * 60

    let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    func judge(_ question: DuplicateQuestion) async throws -> DuplicateVerdict {
        let prompt = DuplicatePrompt.render(question)
        let environment = environment
        let (output, status) = try await Task.detached { () throws -> (String, Int32) in
            let promptFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("superlinear-duplicates-\(UUID().uuidString).prompt")
            try prompt.write(to: promptFile, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: promptFile) }
            let input = try FileHandle(forReadingFrom: promptFile)
            defer { try? input.close() }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = Self.arguments
            process.environment = environment
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = output
            try process.run()
            // A session that hangs must not hold up the proposal for good.
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout) {
                if process.isRunning { process.terminate() }
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (String(decoding: data, as: UTF8.self), process.terminationStatus)
        }.value
        guard status == 0 else {
            throw DuplicateCheckError.claudeFailed("`claude` exited \(status): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return try DuplicatePrompt.verdict(from: output, keys: question.candidates.map(\.key))
    }
}

/// Merging what a new issue adds into the issue it repeats.
enum IssueMerge {
    /// The section added to an issue's text: a heading naming the new issue,
    /// and what it adds.
    static func section(title: String, added: String) -> String {
        "### Also from \"\(title)\"\n\n\(added)"
    }

    /// `text` with `section` added at its end.
    static func appending(_ section: String, to text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? section : text + "\n\n" + section
    }

    /// The edit that adds `section` to `issue`: to its description, when
    /// superlinear created it, or else to its managed block.
    static func edit(_ issue: EditableIssue, adding section: String) -> ProposalPayload {
        let old = issue.createdBySuperlinear ? issue.description : ManagedBlock.contents(of: issue.description) ?? ""
        return .editIssue(oldText: old, newText: appending(section, to: old))
    }

    /// The edit that adds the text of a proposed issue the owner marked a
    /// duplicate of `issue` to it, so that what it says is not lost.
    static func draft(merging proposal: Proposal, text: String, into issue: EditableIssue) -> ProposalDraft {
        ProposalDraft(
            payload: edit(issue, adding: section(title: ProposalForm.issueTitle(proposal), added: text)),
            target: .issue(issue.id, name: issue.identifier),
            reason: "The proposed issue \"\(ProposalForm.issueTitle(proposal))\" was marked a duplicate of \(issue.identifier); "
                + "this adds what it says to \(issue.identifier)",
            source: proposal.source,
            targetUpdatedAt: issue.updatedAt
        )
    }
}
