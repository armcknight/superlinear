import Foundation

/// Work an agent found outside its issue, which it leaves in its worktree's
/// follow-ups file rather than doing it or filing it in Linear itself.
struct FollowUp: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case bug, task, test, spec
    }

    var title: String
    var description: String
    var kind: Kind
    /// The file and line, the failing command, or the log excerpt that shows it.
    var evidence: String
    /// The identifier of an issue it blocks or relates to, such as `SPL-4`.
    var relatedIssue: LinearIssue.Identifier?

    /// The proposal of a new issue for it, in the team of the issue the agent
    /// worked on. `relatedIssueId` is the issue it follows from: its
    /// `relatedIssue`, or else the agent's own issue, so that a match with an
    /// open issue becomes a relation between the two. A GitHub issue's agent
    /// has no Linear issue, so its follow-up may follow from none.
    func draft(
        teamId: LinearTeam.ID, relatedIssueId: LinearIssue.ID?, agentIssue: LinearIssue.Identifier, source: ProposalSource
    ) -> ProposalDraft {
        var lines = [description, "", "Kind: \(kind.rawValue)", "", "Evidence:", "", evidence]
        if let relatedIssue { lines += ["", "Related to \(relatedIssue)."] }
        lines += ["", "Found by the agent working on \(agentIssue)."]
        return ProposalDraft(
            payload: .createIssue(
                teamId: teamId, projectId: nil, title: title, description: lines.joined(separator: "\n"),
                relatedIssueId: relatedIssueId
            ),
            target: .team(teamId),
            reason: "The agent working on \(agentIssue) reported a \(kind.rawValue) outside its issue",
            source: source
        )
    }
}

/// `.superlinear/followups.json` in an agent's worktree: a JSON array of
/// follow-ups, which the daemon turns into proposals when the agent exits.
enum FollowUpFile {
    static let directory = ".superlinear"
    static let name = "followups.json"
    /// The line in the repository's `info/exclude` that keeps the directory
    /// out of git in every worktree.
    static let excludeLine = "/\(directory)/"

    enum Contents: Equatable {
        /// No file, or one with no entries.
        case none
        case entries([FollowUp])
        /// Why the file could not be used. It is left in place.
        case malformed(String)
    }

    static func path(worktree: String) -> String {
        "\(worktree)/\(directory)/\(name)"
    }

    static func read(worktree: String) -> Contents {
        guard let data = FileManager.default.contents(atPath: path(worktree: worktree)) else { return .none }
        return parse(data)
    }

    /// The entries in `data`. An empty file has none. Should any entry be
    /// invalid, none is taken, so that the file is fixed and read whole.
    static func parse(_ data: Data) -> Contents {
        if String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .none
        }
        let entries: [FollowUp]
        do {
            entries = try JSONDecoder().decode([FollowUp].self, from: data)
        } catch {
            return .malformed(describe(error))
        }
        for (index, entry) in entries.enumerated() {
            let blank = [("title", entry.title), ("description", entry.description), ("evidence", entry.evidence)]
                .filter { $0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map(\.0)
            if !blank.isEmpty {
                return .malformed("entry \(index + 1) has no \(blank.joined(separator: " or "))")
            }
        }
        return entries.isEmpty ? .none : .entries(entries)
    }

    /// Leaves `entries` in the file for the next agent's exit, or removes the
    /// file when there are none.
    static func keep(_ entries: [FollowUp], worktree: String) throws {
        let url = URL(fileURLWithPath: path(worktree: worktree))
        guard !entries.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(entries).write(to: url, options: .atomic)
    }

    /// The worktree of `branch` in the repository at `repoPath`, if it has one.
    static func worktree(branch: String, repoPath: String) -> String? {
        guard let porcelain = Git.run(["worktree", "list", "--porcelain"], in: repoPath) else { return nil }
        return WorktreeCleaner.linkedWorktrees(porcelain + "\n").first { $0.branch == branch }?.path
    }

    /// Adds `excludeLine` to the repository's `info/exclude`, which every
    /// worktree shares, unless it is there already.
    static func ignore(repoPath: String) throws {
        guard let commonDirectory = Git.run(["rev-parse", "--git-common-dir"], in: repoPath) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: repoPath])
        }
        let base = commonDirectory.hasPrefix("/") ? commonDirectory : "\(repoPath)/\(commonDirectory)"
        let info = URL(fileURLWithPath: base).appendingPathComponent("info")
        let exclude = info.appendingPathComponent("exclude")
        let current = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
        guard let updated = excluding(current) else { return }
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        try updated.write(to: exclude, atomically: true, encoding: .utf8)
    }

    /// `exclude` with `excludeLine` added, or nil when it has it already.
    static func excluding(_ exclude: String) -> String? {
        let lines = exclude.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.contains(excludeLine), !lines.contains(directory), !lines.contains("\(directory)/") else { return nil }
        let separator = exclude.isEmpty || exclude.hasSuffix("\n") ? "" : "\n"
        return exclude + separator + excludeLine + "\n"
    }

    private static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return "\(error)" }
        func at(_ path: [CodingKey]) -> String {
            guard let first = path.first?.intValue else { return "the file" }
            let rest = path.dropFirst().map(\.stringValue)
            return (["entry \(first + 1)"] + rest).joined(separator: ".")
        }
        return switch error {
        case .keyNotFound(let key, let context): "\(at(context.codingPath)) has no \(key.stringValue)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            "\(at(context.codingPath)): \(context.debugDescription)"
        @unknown default: "\(error)"
        }
    }
}
