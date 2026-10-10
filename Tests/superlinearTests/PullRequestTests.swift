import Foundation
import Testing
@testable import superlinear

// A merge is what marks an issue done and tears down its worktree, so reading
// a PR as merged when it is not would delete work still under review.
@Suite("Pull request checks")
struct PullRequestTests {
    private func pr(_ number: Int, _ state: PullRequest.State) -> PullRequest {
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

    @Test("The list covers closed and merged pull requests from the issue's branch")
    func listArguments() {
        let args = PullRequestChecker.listArguments(branch: "linear/sl-1-x")
        #expect(args.starts(with: ["gh", "pr", "list"]))
        #expect(args.contains("--head"))
        #expect(args[args.firstIndex(of: "--head")! + 1] == "linear/sl-1-x")
        #expect(args[args.firstIndex(of: "--state")! + 1] == "all")
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
