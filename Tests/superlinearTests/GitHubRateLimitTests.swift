import Foundation
import Testing
@testable import superlinear

// While a rate limit is used up every gh call fails, so the daemon must know
// one when it sees it, and wait for the right reset.
@Suite("GitHub rate limits")
struct GitHubRateLimitTests {
    @Test("Rate-limit failures are told apart from others")
    func recognizesRateLimits() {
        #expect(GitHubRateLimit.isRateLimit(StatusError.gitHub("GraphQL: API rate limit already exceeded for user ID 1.")))
        #expect(GitHubRateLimit.isRateLimit(StatusError.gitHub("You have exceeded a secondary rate limit.")))
        #expect(!GitHubRateLimit.isRateLimit(StatusError.gitHub("Could not resolve to a Repository")))
    }

    @Test("GraphQL's reset counts only when no points remain")
    func graphQLReset() {
        let spent = #"{"data":{"rateLimit":{"remaining":0,"resetAt":"2026-10-12T23:36:58Z"}}}"#
        let left = #"{"data":{"rateLimit":{"remaining":12,"resetAt":"2026-10-12T23:36:58Z"}}}"#
        #expect(GitHubRateLimit.graphQLReset(Data(spent.utf8)) == ISO8601DateFormatter().date(from: "2026-10-12T23:36:58Z"))
        #expect(GitHubRateLimit.graphQLReset(Data(left.utf8)) == nil)
        #expect(GitHubRateLimit.graphQLReset(Data("garbage".utf8)) == nil)
    }

    @Test("REST's reset counts only when no requests remain")
    func restReset() {
        let spent = #"{"resources":{"core":{"limit":5000,"remaining":0,"reset":1791848218}}}"#
        let left = #"{"resources":{"core":{"limit":5000,"remaining":1,"reset":1791848218}}}"#
        #expect(GitHubRateLimit.restReset(Data(spent.utf8)) == Date(timeIntervalSince1970: 1_791_848_218))
        #expect(GitHubRateLimit.restReset(Data(left.utf8)) == nil)
    }

    @Test("Status finds a rate-limited workspace's repository to ask about the reset")
    func rateLimitedRepoPath() throws {
        let json = #"{"workspaces":[{"name":"a","apiKey":"k","repoPath":"/r/a"},{"name":"b","apiKey":"k","repoPath":"/r/b"}]}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        let clean = WorkspaceReport(name: "a", entries: [], warnings: [])
        let limited = WorkspaceReport(name: "b", entries: [], warnings: ["Could not list: GraphQL: API rate limit already exceeded"])
        #expect(StatusCommand.rateLimitedRepoPath([clean, limited], workspaces: config.workspaces) == "/r/b")
        #expect(StatusCommand.rateLimitedRepoPath([clean, clean], workspaces: config.workspaces) == nil)
    }
}
