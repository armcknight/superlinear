import Foundation
import Testing
@testable import superlinear

@Suite("Pull requests for review")
struct PullRequestReviewTests {
    private func pr(
        _ number: PullRequest.Number, branch: String = "linear/spl-5-status", title: String = "t", draft: Bool = false,
        decision: String? = "", reviews: [String] = [], checks: [ReviewablePullRequest.Check] = []
    ) -> ReviewablePullRequest {
        ReviewablePullRequest(
            number: number, url: "https://github.com/o/r/pull/\(number)", title: title, headRefName: branch,
            isDraft: draft, reviewDecision: decision, latestReviews: reviews.map { .init(state: $0) },
            statusCheckRollup: checks
        )
    }

    private func issue(_ identifier: LinearIssue.Identifier) -> LinearIssueStatus {
        LinearIssueStatus(
            id: "id-\(identifier)", identifier: identifier, title: "Issue \(identifier)", branchName: "b",
            state: .init(name: "In Review", type: "started")
        )
    }

    @Test("Issue identifiers come from the branch and the title, once each")
    func identifiers() {
        #expect(pr(1, branch: "linear/spl-5-status-function").issueIdentifiers == ["SPL-5"])
        #expect(pr(1, branch: "fix-thing", title: "MTG-28: Tempo analysis").issueIdentifiers == ["MTG-28"])
        #expect(pr(1, branch: "linear/mtg-28-tempo", title: "MTG-28: Tempo").issueIdentifiers == ["MTG-28"])
        #expect(pr(1, branch: "main", title: "chore: tidy up").issueIdentifiers.isEmpty)
    }

    @Test("GitHub's decision wins; without one, the latest reviews decide")
    func reviewState() {
        #expect(pr(1, decision: "APPROVED").reviewState == .approved)
        #expect(pr(1, decision: "REVIEW_REQUIRED", reviews: ["APPROVED"]).reviewState == .notReviewed)
        #expect(pr(1, decision: "", reviews: ["COMMENTED"]).reviewState == .notReviewed)
        #expect(pr(1, decision: nil, reviews: ["APPROVED", "CHANGES_REQUESTED"]).reviewState == .changesRequested)
        #expect(pr(1, decision: "", reviews: ["APPROVED"]).reviewState == .approved)
    }

    @Test("Checks roll up to failing, running, passing or none")
    func checkState() {
        typealias Check = ReviewablePullRequest.Check
        let passed = Check(status: "COMPLETED", conclusion: "SUCCESS")
        #expect(pr(1).checkState == .none)
        #expect(pr(1, checks: [passed, Check(status: "COMPLETED", conclusion: "SKIPPED")]).checkState == .passing)
        #expect(pr(1, checks: [passed, Check(status: "IN_PROGRESS", conclusion: "")]).checkState == .pending)
        #expect(pr(1, checks: [Check(status: "IN_PROGRESS"), Check(status: "COMPLETED", conclusion: "FAILURE")]).checkState == .failing)
        #expect(pr(1, checks: [Check(state: "PENDING")]).checkState == .pending)
        #expect(pr(1, checks: [Check(state: "ERROR")]).checkState == .failing)
    }

    @Test("Only pull requests naming an issue Linear has are listed, sorted by issue")
    func entries() {
        let entries = ReviewEntry.entries(
            pullRequests: [
                pr(3, branch: "linear/spl-10-x"), pr(1, branch: "linear/spl-9-y"),
                pr(2, branch: "linear/zzz-1-unknown"), pr(4, branch: "main"),
            ],
            issues: [issue("SPL-10"), issue("SPL-9")]
        )
        #expect(entries.map(\.issue.identifier) == ["SPL-9", "SPL-10"])
    }

    @Test("Review and draft sections replace the tasks' open pull requests")
    func rendering() {
        let report = WorkspaceReport(
            name: "w",
            entries: [TaskEntry(identifier: "SPL-5", title: "Status", category: .openPullRequest, detail: "u")],
            reviews: [
                ReviewEntry(issue: issue("SPL-5"), pullRequest: pr(2, title: "feat: status", checks: [.init(status: "COMPLETED", conclusion: "SUCCESS")])),
                ReviewEntry(issue: issue("SPL-6"), pullRequest: pr(3, title: "wip", draft: true)),
            ],
            warnings: []
        )
        let text = report.rendered()
        #expect(text.contains("Awaiting review"))
        #expect(text.contains("#2 feat: status"))
        #expect(text.contains("not reviewed · CI passing · https://github.com/o/r/pull/2"))
        #expect(text.contains("Draft pull requests"))
        #expect(text.contains("no CI · https://github.com/o/r/pull/3"))
        #expect(!text.contains("Open pull requests"))
    }

    @Test("gh's JSON decodes, check runs and commit statuses alike")
    func decodes() throws {
        let json = #"[{"headRefName":"linear/cla-8-x","isDraft":false,"latestReviews":[],"number":12,"reviewDecision":"","statusCheckRollup":[{"__typename":"CheckRun","conclusion":"SUCCESS","name":"ci","status":"COMPLETED"},{"__typename":"StatusContext","context":"ci/x","state":"SUCCESS"}],"title":"feat: x","url":"https://github.com/o/r/pull/12"}]"#
        let prs = try JSONDecoder().decode([ReviewablePullRequest].self, from: Data(json.utf8))
        #expect(prs.first?.checkState == .passing)
        #expect(prs.first?.issueIdentifiers == ["CLA-8"])
    }
}
