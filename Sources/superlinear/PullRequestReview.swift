import Foundation

/// An open pull request as `superlinear status` lists it for review, with what
/// GitHub knows about its reviews and checks.
struct ReviewablePullRequest: Codable, Sendable, Equatable {
    let number: PullRequest.Number
    let url: String
    let title: String
    let headRefName: String
    let isDraft: Bool
    /// `REVIEW_REQUIRED`, `CHANGES_REQUESTED` or `APPROVED`; empty where the
    /// repository requires no review.
    let reviewDecision: String?
    let latestReviews: [Review]?
    let statusCheckRollup: [Check]?
    var additions: Int? = nil
    var deletions: Int? = nil
    var changedFiles: Int? = nil
    var baseRefName: String? = nil
    /// `MERGEABLE`, `CONFLICTING` or `UNKNOWN`.
    var mergeable: String? = nil

    struct Review: Codable, Sendable, Equatable {
        /// `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED` and so on.
        let state: String
    }

    /// A check run (`status`, `conclusion`) or a commit status (`state`).
    struct Check: Codable, Sendable, Equatable {
        var status: String? = nil
        var conclusion: String? = nil
        var state: String? = nil
    }

    static let jsonFields =
        "number,url,title,headRefName,isDraft,reviewDecision,latestReviews,statusCheckRollup,additions,deletions,changedFiles,baseRefName,mergeable"

    enum ReviewState: String, Equatable {
        case notReviewed = "not reviewed"
        case changesRequested = "changes requested"
        case approved = "approved"
    }

    /// GitHub's decision where the repository requires reviews; otherwise the
    /// latest approval or change request, if anyone left one.
    var reviewState: ReviewState {
        switch reviewDecision {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        case "REVIEW_REQUIRED": return .notReviewed
        default:
            let states = Set((latestReviews ?? []).map(\.state))
            if states.contains("CHANGES_REQUESTED") { return .changesRequested }
            if states.contains("APPROVED") { return .approved }
            return .notReviewed
        }
    }

    enum CheckState: String, Equatable {
        case none = "no CI"
        case pending = "CI running"
        case failing = "CI failing"
        case passing = "CI passing"
        /// Failing, but only because the GitHub Actions spending limit kept
        /// its jobs from starting: nothing to fix in the code.
        case notStarted = "CI not started: GitHub spending limit"
    }

    /// `checkState`, with failing checks on a branch whose CI the spending
    /// limit stopped told apart from real failures.
    func checkState(stoppedBranches: Set<String>) -> CheckState {
        let state = checkState
        return state == .failing && stoppedBranches.contains(headRefName) ? .notStarted : state
    }

    var checkState: CheckState { Self.checkState(of: statusCheckRollup) }

    /// What the checks say together: failing if any did, else pending if any
    /// is, else passing; no CI when there are none.
    static func checkState(of checks: [Check]?) -> CheckState {
        let checks = checks ?? []
        guard !checks.isEmpty else { return .none }
        let failed: Set<String> = ["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"]
        if checks.contains(where: { failed.contains($0.conclusion ?? "") || failed.contains($0.state ?? "") }) {
            return .failing
        }
        let pending = checks.contains { check in
            if let state = check.state { return state == "PENDING" || state == "EXPECTED" }
            return check.status != "COMPLETED"
        }
        return pending ? .pending : .passing
    }

    /// Identifiers of Linear issues the branch or title names, such as SPL-5
    /// in `linear/spl-5-status-function` or "SPL-5: Status". Whether each
    /// exists is for Linear to say.
    var issueIdentifiers: [LinearIssue.Identifier] {
        var identifiers: [LinearIssue.Identifier] = []
        func add(_ key: Substring, _ number: Substring) {
            let identifier = LinearIssue.Identifier(rawValue: "\(key.uppercased())-\(number)")
            if !identifiers.contains(identifier) { identifiers.append(identifier) }
        }
        for match in headRefName.matches(of: /(?i)(?:^|[^a-z0-9])([a-z][a-z0-9]*)-(\d+)(?![0-9])/) {
            add(match.output.1, match.output.2)
        }
        for match in title.matches(of: /(?:^|[^A-Za-z0-9])([A-Z][A-Z0-9]*)-(\d+)(?![0-9])/) {
            add(match.output.1, match.output.2)
        }
        return identifiers
    }

    /// The repository's open pull requests, from `gh`.
    static func listOpen(in repoPath: String) throws -> [ReviewablePullRequest] {
        let data = try GitHubCLI.run(
            ["pr", "list", "--state", "open", "--limit", "1000", "--json", jsonFields], in: repoPath)
        return try JSONDecoder().decode([ReviewablePullRequest].self, from: data)
    }
}

/// An open pull request matched to the Linear issue it belongs to.
struct ReviewEntry: Sendable, Equatable {
    let issue: LinearIssueStatus
    let pullRequest: ReviewablePullRequest

    /// Pairs each open pull request with the first issue it names that Linear
    /// has. Pull requests naming none are left out. Sorted by issue, then PR.
    static func entries(pullRequests: [ReviewablePullRequest], issues: [LinearIssueStatus]) -> [ReviewEntry] {
        let byIdentifier = Dictionary(issues.map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
        return pullRequests.compactMap { pullRequest in
            pullRequest.issueIdentifiers.lazy.compactMap { byIdentifier[$0] }.first.map {
                ReviewEntry(issue: $0, pullRequest: pullRequest)
            }
        }.sorted { a, b in
            a.issue.identifier == b.issue.identifier
                ? a.pullRequest.number < b.pullRequest.number
                : a.issue.identifier.sortsBefore(b.issue.identifier)
        }
    }
}
