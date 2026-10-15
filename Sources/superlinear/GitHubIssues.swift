import Foundation

/// An issue in a workspace's GitHub repository, as `gh issue list --json`
/// reports it. Agents work on the ones you opened, and on others you asked
/// for by commenting `/superlinear-do`.
struct GitHubIssue: Codable, Sendable, Equatable {
    let number: Int
    let title: String
    var createdAt: Date? = nil
    var author: User? = nil
    var comments: [Comment]? = nil
    /// `OPEN` or `CLOSED`, when the listing asked for it.
    var state: String? = nil
    /// `COMPLETED`, `NOT_PLANNED` and so on, once closed.
    var stateReason: String? = nil

    struct User: Codable, Sendable, Equatable {
        let login: String
    }

    struct Comment: Codable, Sendable, Equatable {
        let author: User?
        let body: String
    }

    /// The comment that asks for an agent on an issue someone else opened.
    static let command = "/superlinear-do"

    /// Prefixes the issue IDs kept in the state file, which Linear's IDs
    /// never start with.
    static let idPrefix = "github:"

    var issueId: String { Self.issueId(number: number) }
    /// The identifier used in logs and `superlinear status`. Its shape is a
    /// Linear identifier's, so the review list finds the issue from its branch.
    var identifier: String { "GH-\(number)" }
    /// Named by number alone, so a later edit to the title cannot lose it.
    var branchName: String { Self.branchName(number: number) }

    static func issueId(number: Int) -> String { "\(idPrefix)\(number)" }
    static func branchName(number: Int) -> String { "github/gh-\(number)" }

    /// The issue number of a state file ID, if it is a GitHub one.
    static func number(ofIssueId id: String) -> Int? {
        guard id.hasPrefix(idPrefix) else { return nil }
        return Int(id.dropFirst(idPrefix.count))
    }

    /// Whether `login` asked for an agent on this issue: by opening it at or
    /// after `openedSince`, or by commenting a line that starts with
    /// `/superlinear-do`, at any time.
    func isRequested(by login: String, openedSince: Date) -> Bool {
        if author?.login == login, let createdAt, createdAt >= openedSince { return true }
        return (comments ?? []).contains { comment in
            comment.author?.login == login && Self.containsCommand(comment.body)
        }
    }

    static func containsCommand(_ body: String) -> Bool {
        body.split(whereSeparator: \.isNewline).contains { line in
            let words = line.split(whereSeparator: \.isWhitespace)
            return words.first.map(String.init) == command
        }
    }

    /// The issue as the status report shows it, its state named in Linear's
    /// terms so it sorts the same way.
    var status: LinearIssueStatus {
        let type: String
        switch (state, stateReason) {
        case ("CLOSED", "COMPLETED"?): type = "completed"
        case ("CLOSED", _): type = "canceled"
        default: type = "unstarted"
        }
        return LinearIssueStatus(
            id: issueId, identifier: identifier, title: title, branchName: branchName,
            state: .init(name: state == "CLOSED" ? "closed" : "open", type: type)
        )
    }
}

/// Asks `gh` about a repository's issues.
struct GitHubIssueClient: Sendable {
    let checker = PullRequestChecker()

    static let listOpenArguments = [
        "gh", "issue", "list", "--state", "open", "--limit", "1000", "--json", "number,title,createdAt,author,comments",
    ]
    static let listAllArguments = [
        "gh", "issue", "list", "--state", "all", "--limit", "1000", "--json", "number,title,state,stateReason",
    ]

    /// The repository's open issues, newest 1,000, with their comments.
    func openIssues(repoPath: String) async throws -> [GitHubIssue] {
        try Self.decode(try await checker.run(Self.listOpenArguments, in: repoPath))
    }

    /// Closes the issue as completed. Returns false, changing nothing, when it
    /// is closed already, as when its pull request said `Closes #N`.
    func completeIssue(number: Int, repoPath: String) async throws -> Bool {
        let output = try await checker.run(
            ["gh", "issue", "view", "\(number)", "--json", "number,title,state"], in: repoPath)
        let issue = try JSONDecoder().decode(GitHubIssue.self, from: output)
        guard issue.state != "CLOSED" else { return false }
        _ = try await checker.run(["gh", "issue", "close", "\(number)", "--reason", "completed"], in: repoPath)
        return true
    }

    static func decode(_ data: Data) throws -> [GitHubIssue] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([GitHubIssue].self, from: data)
    }

    /// Every issue in the repository, newest 1,000, with its state, for
    /// `superlinear status`.
    static func allIssues(in repoPath: String) throws -> [GitHubIssue] {
        try decode(try GitHubCLI.run(Array(listAllArguments.dropFirst()), in: repoPath))
    }
}
