import Foundation
import Testing
@testable import superlinear

// A merge is what marks an issue done and tears down its worktree, so reading
// a PR as merged when it is not would delete work still under review.
@Suite("Pull request checks")
struct PullRequestTests {
    private func pr(_ number: PullRequest.Number, _ state: PullRequest.State) -> PullRequest {
        PullRequest(number: number, url: "https://github.com/o/r/pull/\(number)", state: state)
    }

    @Test("gh's JSON decodes")
    func decodesGhOutput() throws {
        let json = #"[{"number":7,"state":"MERGED","url":"https://github.com/o/r/pull/7"}]"#
        #expect(try PullRequestChecker.decodePullRequests(Data(json.utf8)) == [pr(7, .merged)])
    }

    @Test("No pull requests decode to an empty list")
    func decodesEmptyList() throws {
        #expect(try PullRequestChecker.decodePullRequests(Data("[]".utf8)).isEmpty)
    }

    @Test("An unknown state is an error rather than a guess")
    func unknownStateThrows() {
        #expect(throws: DecodingError.self) {
            _ = try PullRequestChecker.decodePullRequests(Data(#"[{"number":1,"state":"DRAFT","url":"u"}]"#.utf8))
        }
    }

    @Test("Open pull requests are listed with their branches, reviews and head commits")
    func listOpenArguments() {
        let args = PullRequestChecker.listOpenArguments
        #expect(args.starts(with: ["gh", "pr", "list"]))
        #expect(args[args.firstIndex(of: "--state")! + 1] == "open")
        #expect(!args.contains("--head"))
        let fields = args.last?.split(separator: ",") ?? []
        #expect(["headRefName", "headRefOid", "reviews"].allSatisfy { fields.contains($0[...]) })
        // A page of 100 pull requests with their commit lists is refused.
        #expect(!fields.contains("commits"))
    }

    // The merge check takes the repository-wide listing for state, and the
    // open listing for what only it has.
    @Test("Open pull requests take their reviews and head commits from the open listing")
    func mergeListings() {
        let review = PullRequestReview(author: .init(login: "me"), state: "COMMENTED", body: "", submittedAt: nil)
        let all = [
            PullRequest(number: 1, url: "u1", state: .merged, headRefName: "b"),
            PullRequest(number: 2, url: "u2", state: .open, headRefName: "b"),
            PullRequest(number: 3, url: "u3", state: .open, headRefName: "b"),
        ]
        let open = [PullRequest(number: 2, url: "u2", state: .open, headRefName: "b", reviews: [review])]
        let merged = PullRequestListing.merge(all, withOpen: open)
        #expect(merged.map(\.number) == [1, 2, 3])
        #expect(merged[0].reviews == nil)
        #expect(merged[1].reviews == [review])
        // Opened between the two listings: kept, without reviews.
        #expect(merged[2].reviews == nil)
    }

    // A watch from before reviews were followed starts from the head commit,
    // so a review left after the last push is still answered.
    @Test("The head commit's date is asked of the REST API, and the head comes with open pull requests")
    func headCommit() throws {
        #expect(PullRequestChecker.commitDateArguments(sha: "abc") == [
            "gh", "api", "repos/{owner}/{repo}/commits/abc", "--jq", ".commit.committer.date",
        ])
        let json = #"[{"number":1,"url":"u","state":"OPEN","headRefOid":"abc"}]"#
        #expect(try PullRequestChecker.decodePullRequests(Data(json.utf8)).first?.headRefOid == "abc")
    }

    @Test("Reviews decode from gh's JSON, whatever their state")
    func decodesReviews() throws {
        let json = #"""
        [{"number":7,"state":"OPEN","url":"u","reviews":[
          {"id":"PRR_1","author":{"login":"me"},"authorAssociation":"OWNER","body":"Rename this",
           "submittedAt":"2026-10-11T12:00:00Z","state":"CHANGES_REQUESTED","commit":{"oid":"abc"}},
          {"id":"PRR_2","author":{"login":"me"},"body":"","submittedAt":null,"state":"SOME_NEW_STATE"}
        ]}]
        """#
        let reviews = try #require(try PullRequestChecker.decodePullRequests(Data(json.utf8)).first?.reviews)
        #expect(reviews.count == 2)
        #expect(reviews[0] == review("me", "CHANGES_REQUESTED", body: "Rename this", at: 1_791_720_000))
        #expect(reviews[1].submittedAt == nil)
        #expect(!reviews[1].asksForChanges)
    }

    private func review(_ login: String, _ state: String, body: String = "", at seconds: TimeInterval?) -> PullRequestReview {
        PullRequestReview(
            author: .init(login: login), state: state, body: body,
            submittedAt: seconds.map(Date.init(timeIntervalSince1970:))
        )
    }

    // A review that slips through starts an agent that pushes to the branch, so
    // only the signed-in user's new reviews that ask for something count.
    @Test("Only new reviews from the signed-in user that ask for changes count")
    func unaddressedReviews() {
        let reviews = [
            review("me", "COMMENTED", at: 200),
            review("me", "CHANGES_REQUESTED", body: "Fix it", at: 300),
            review("me", "APPROVED", body: "Nit: rename x", at: 400),
            review("me", "APPROVED", body: " \n", at: 500),
            review("me", "PENDING", body: "Draft", at: nil),
            review("me", "DISMISSED", body: "Old", at: 600),
            review("me", "COMMENTED", body: "Before the agent", at: 100),
            review("me", "COMMENTED", body: "Exactly at the start", at: 150),
            review("seer-by-sentry[bot]", "COMMENTED", body: "Bug", at: 700),
        ]
        let found = PullRequestReview.unaddressed(reviews, by: "me", after: Date(timeIntervalSince1970: 150))
        #expect(found == Array(reviews[0..<3]))
        #expect(PullRequestReview.unaddressed(reviews, by: "someone", after: .distantPast).isEmpty)
    }

    @Test("The latest change request from before the stopped agent's log is answered again")
    func reviewsStoppedAtUsageLimit() {
        let asked = [review("me", "APPROVED", at: 100), review("me", "CHANGES_REQUESTED", body: "Fix it", at: 200)]
        let log = Date(timeIntervalSince1970: 300)
        #expect(PullRequestReview.stoppedAtUsageLimit(asked, by: "me", logWrittenAt: log))
        // Approved since, after the log, by someone else, or no log.
        #expect(!PullRequestReview.stoppedAtUsageLimit(asked + [review("me", "APPROVED", at: 250)], by: "me", logWrittenAt: log))
        #expect(!PullRequestReview.stoppedAtUsageLimit(asked, by: "me", logWrittenAt: Date(timeIntervalSince1970: 150)))
        #expect(!PullRequestReview.stoppedAtUsageLimit(asked, by: "someone", logWrittenAt: log))
        #expect(!PullRequestReview.stoppedAtUsageLimit(asked, by: "me", logWrittenAt: nil))
    }

    @Test("A branch with no pull request is missing")
    func missing() {
        #expect(MergeStatus.of([]) == .missing)
    }

    @Test("An open pull request keeps the watch going")
    func open() {
        #expect(MergeStatus.of([pr(1, .open)]) == .open)
    }

    @Test("A merged pull request wins over any other on the branch")
    func mergeWins() {
        #expect(MergeStatus.of([pr(2, .closed), pr(3, .merged), pr(4, .open)]) == .merged(pr(3, .merged)))
    }

    @Test("A closed pull request reopened as another is still open")
    func reopened() {
        #expect(MergeStatus.of([pr(2, .open), pr(1, .closed)]) == .open)
    }

    @Test("Only closed pull requests mean closed")
    func closed() {
        #expect(MergeStatus.of([pr(1, .closed)]) == .closed(pr(1, .closed)))
    }
}
