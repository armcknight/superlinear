import Foundation
import Testing
@testable import superlinear

// Agents must work only on issues you asked for: ones you opened, or ones you
// commented `/superlinear-do` on. Anyone else's issue or comment is ignored.
@Suite("GitHub issues")
struct GitHubIssueTests {
    private let since = Date(timeIntervalSince1970: 1_000)

    private func issue(
        by author: String, at seconds: TimeInterval = 2_000, comments: [(String, String)] = []
    ) -> GitHubIssue {
        GitHubIssue(
            number: 7, title: "Fix it", createdAt: Date(timeIntervalSince1970: seconds),
            author: .init(login: author),
            comments: comments.map { .init(author: .init(login: $0.0), body: $0.1) }
        )
    }

    @Test("An issue you opened since polling began is requested")
    func openedByYou() {
        #expect(issue(by: "me").isRequested(by: "me", openedSince: since))
        #expect(!issue(by: "me", at: 500).isRequested(by: "me", openedSince: since))
    }

    @Test("Someone else's issue needs your /superlinear-do comment")
    func openedBySomeoneElse() {
        #expect(!issue(by: "them").isRequested(by: "me", openedSince: since))
        #expect(!issue(by: "them", comments: [("them", "/superlinear-do")]).isRequested(by: "me", openedSince: since))
        #expect(issue(by: "them", comments: [("me", "/superlinear-do")]).isRequested(by: "me", openedSince: since))
    }

    @Test("Your older issue is requested once you comment /superlinear-do")
    func olderIssueOfYours() {
        #expect(issue(by: "me", at: 500, comments: [("me", "/superlinear-do")]).isRequested(by: "me", openedSince: since))
    }

    @Test("The command counts at the start of any line, and only there")
    func command() {
        #expect(GitHubIssue.containsCommand("/superlinear-do"))
        #expect(GitHubIssue.containsCommand("Looks good.\n  /superlinear-do please"))
        #expect(!GitHubIssue.containsCommand("don't /superlinear-do this"))
        #expect(!GitHubIssue.containsCommand("/superlinear-done"))
    }

    @Test("IDs, identifiers and branches are named by number")
    func naming() {
        let issue = issue(by: "me")
        #expect(issue.issueId == "github:7")
        #expect(issue.identifier == "GH-7")
        #expect(issue.branchName == "github/gh-7")
        #expect(GitHubIssue.number(ofIssueId: "github:7") == 7)
        #expect(GitHubIssue.number(ofIssueId: "4a6b-uuid") == nil)
    }

    @Test("Closed as completed is done; closed otherwise is canceled")
    func status() {
        func status(_ state: String, _ reason: String?) -> String {
            GitHubIssue(number: 1, title: "t", state: state, stateReason: reason).status.state.type
        }
        #expect(status("OPEN", nil) == "unstarted")
        #expect(status("CLOSED", "COMPLETED") == "completed")
        #expect(status("CLOSED", "NOT_PLANNED") == "canceled")
    }

    @Test("A listing from gh decodes")
    func decodes() throws {
        let issues = try GitHubIssueClient.decode(Data("""
        [{"number": 3, "title": "t", "createdAt": "2026-10-12T12:00:00Z", "author": {"login": "me"},
          "comments": [{"author": {"login": "you"}, "body": "hi"}]}]
        """.utf8))
        #expect(issues.first?.author?.login == "me")
        #expect(issues.first?.comments?.first?.body == "hi")
    }

    @Test("The open pull request of a GitHub issue's branch names it")
    func reviewMatch() {
        let pullRequest = ReviewablePullRequest(
            number: 9, url: "u", title: "fix: it", headRefName: "github/gh-7", isDraft: false,
            reviewDecision: nil, latestReviews: nil, statusCheckRollup: nil
        )
        let issue = GitHubIssue(number: 7, title: "Fix it", state: "OPEN").status
        #expect(ReviewEntry.entries(pullRequests: [pullRequest], issues: [issue]).first?.issue.id == "github:7")
    }
}
