import Foundation
import Testing
@testable import superlinear

// The sweep completes issues in Linear, so it must not complete one still
// being worked on: a follow-up pull request is open, or the issue was moved
// back into progress after its merge.
@Suite("Started issue sweep")
struct StartedIssueSweepTests {
    private func issue(_ id: String, startedAt: TimeInterval? = 100) -> LinearIssueStatus {
        LinearIssueStatus(
            id: id, identifier: .init(rawValue: id), title: "t", branchName: "linear/\(id)",
            state: .init(name: "In Review", type: "started"),
            startedAt: startedAt.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private func pr(_ number: PullRequest.Number, _ branch: String, _ state: PullRequest.State, mergedAt: TimeInterval? = nil) -> PullRequest {
        PullRequest(
            number: number, url: "https://github.com/o/r/pull/\(number)", state: state, headRefName: branch,
            mergedAt: mergedAt.map { Date(timeIntervalSince1970: $0) }
        )
    }

    @Test("A merge after the issue started completes it, and its pull requests are listed")
    func mergeCompletes() {
        let items = StartedIssueSweep.plan(
            issues: [issue("a")],
            pullRequests: [pr(1, "linear/a", .closed), pr(2, "linear/a", .merged, mergedAt: 200), pr(3, "other", .merged, mergedAt: 200)],
            excluding: []
        )
        #expect(items.count == 1)
        #expect(items.first?.pullRequests.map(\.number) == [1, 2])
        #expect(items.first?.merged?.number == 2)
    }

    @Test("An open follow-up pull request holds off completion, but is still linked")
    func openPullRequestWaits() {
        let items = StartedIssueSweep.plan(
            issues: [issue("a")],
            pullRequests: [pr(1, "linear/a", .merged, mergedAt: 200), pr(2, "linear/a", .open)],
            excluding: []
        )
        #expect(items.first?.merged == nil)
        #expect(items.first?.pullRequests.count == 2)
    }

    @Test("An issue moved back into progress after its merge stays started")
    func reopenedAfterMerge() {
        let items = StartedIssueSweep.plan(
            issues: [issue("a", startedAt: 300)],
            pullRequests: [pr(1, "linear/a", .merged, mergedAt: 200)],
            excluding: []
        )
        #expect(items.first?.merged == nil)
    }

    @Test("Issues the daemon follows itself, or without pull requests, are left out")
    func exclusions() {
        let items = StartedIssueSweep.plan(
            issues: [issue("tracked"), issue("bare")],
            pullRequests: [pr(1, "linear/tracked", .merged, mergedAt: 200)],
            excluding: ["tracked"]
        )
        #expect(items.isEmpty)
    }

    @Test("gh's listing with merge times decodes")
    func decodesMergedAt() throws {
        let json = #"[{"headRefName":"linear/a","mergedAt":"2026-10-12T04:59:33Z","number":2,"state":"MERGED","url":"u"}]"#
        let prs = try PullRequestChecker.decodePullRequests(Data(json.utf8))
        #expect(prs.first?.mergedAt == ISO8601DateFormatter().date(from: "2026-10-12T04:59:33Z"))
    }
}
