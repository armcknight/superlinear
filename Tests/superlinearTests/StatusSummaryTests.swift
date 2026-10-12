import Foundation
import Testing
@testable import superlinear

// The summary is the one place to see what the agents cost. Counting a
// message twice, or a night's sleep as work, would make that look worse than
// it is.
@Suite("Status summary")
struct StatusSummaryTests {
    private func line(_ time: String, id: String? = nil, input: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0, output: Int = 0) -> String {
        guard let id else { return #"{"type":"user","timestamp":"\#(time)"}"# }
        return #"{"type":"assistant","timestamp":"\#(time)","message":{"id":"\#(id)","usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(cacheWrite),"cache_read_input_tokens":\#(cacheRead),"output_tokens":\#(output)}}}"#
    }

    private func transcript(_ lines: [String], subagent: Bool = false) -> (data: Data, isSubagent: Bool) {
        (Data(lines.joined(separator: "\n").utf8), subagent)
    }

    // MARK: Usage

    @Test("Each message's tokens count once, though Claude repeats them per content block")
    func messagesCountOnce() {
        let usage = AgentUsage.of([transcript([
            line("2026-10-10T00:00:00.000Z", id: "m1", input: 2, cacheWrite: 100, cacheRead: 1000, output: 10),
            line("2026-10-10T00:00:01.000Z", id: "m1", input: 2, cacheWrite: 100, cacheRead: 1000, output: 10),
            line("2026-10-10T00:00:02.000Z", id: "m2", input: 1, cacheRead: 500, output: 5),
            "not json",
        ])])
        #expect(usage.inputTokens == 103)
        #expect(usage.outputTokens == 15)
        #expect(usage.cacheReadTokens == 1500)
        #expect(usage.tokens == 118)
    }

    @Test("Active time leaves out long idle gaps")
    func activeTime() {
        let usage = AgentUsage.of([transcript([
            line("2026-10-10T00:00:00.000Z"),
            line("2026-10-10T00:10:00.000Z"),
            // Asleep overnight, then resumed.
            line("2026-10-10T08:00:00.000Z"),
            line("2026-10-10T08:05:00.500Z"),
        ])])
        #expect(usage.activeTime == 15 * 60 + 0.5)
    }

    @Test("Subagents' tokens count, but their time runs within the main session's")
    func subagents() {
        let usage = AgentUsage.of([
            transcript([line("2026-10-10T00:00:00.000Z"), line("2026-10-10T00:01:00.000Z", id: "m1", output: 1)]),
            transcript([line("2026-10-10T00:00:30.000Z", id: "s1", output: 2), line("2026-10-10T00:20:00.000Z")], subagent: true),
        ])
        #expect(usage.outputTokens == 3)
        #expect(usage.activeTime == 60)
    }

    @Test("Sessions are found by the worktree's branch, also from a moved repository, subagents included")
    func transcriptsByBranch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fm = FileManager.default
        let old = "\(root)/-Users-me-repos-private-app-worktrees-linear-app-1-do-it"
        let new = "\(root)/-Users-me-repos-public-app-worktrees-linear-app-1-do-it"
        let other = "\(root)/-Users-me-repos-public-app-worktrees-linear-app-11-do-it"
        for directory in [old, "\(new)/s2/subagents", other] {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        fm.createFile(atPath: "\(old)/s1.jsonl", contents: Data(line("2026-10-10T00:00:00Z", id: "a", output: 1).utf8))
        fm.createFile(atPath: "\(new)/s2.jsonl", contents: Data(line("2026-10-10T00:00:00Z", id: "b", output: 2).utf8))
        fm.createFile(atPath: "\(new)/s2/subagents/x.jsonl", contents: Data(line("2026-10-10T00:00:00Z", id: "c", output: 4).utf8))
        fm.createFile(atPath: "\(other)/s3.jsonl", contents: Data(line("2026-10-10T00:00:00Z", id: "d", output: 8).utf8))

        let transcripts = Transcripts(root: root)
        #expect(transcripts.directories(forBranch: "linear/app-1-do-it") == [old, new])
        #expect(transcripts.usage(forBranch: "linear/app-1-do-it")?.outputTokens == 7)
        #expect(transcripts.usage(forBranch: "linear/app-2") == nil)
        #expect(transcripts.usage(forBranch: "") == nil)
    }

    // MARK: CI

    @Test("CI time sums each branch's finished runs")
    func ciTime() throws {
        let json = #"""
        [{"headBranch":"a","status":"completed","startedAt":"2026-10-10T00:00:00Z","updatedAt":"2026-10-10T00:02:00Z"},
         {"headBranch":"a","status":"completed","startedAt":"2026-10-10T01:00:00Z","updatedAt":"2026-10-10T01:01:00Z"},
         {"headBranch":"a","status":"in_progress","startedAt":"2026-10-10T02:00:00Z","updatedAt":"2026-10-10T02:05:00Z"},
         {"headBranch":"b","status":"completed","startedAt":"2026-10-10T00:00:00Z","updatedAt":"2026-10-10T00:00:30Z"}]
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let runs = try decoder.decode([WorkflowRun].self, from: Data(json.utf8))
        #expect(WorkflowRun.time(byBranch: runs) == ["a": 180, "b": 30])
    }

    // MARK: Pull requests

    private func task(_ identifier: String, _ category: TaskCategory, pr: PullRequest? = nil) -> TaskEntry {
        TaskEntry(identifier: identifier, title: "", category: category, detail: nil, branch: identifier, pullRequest: pr)
    }

    private func pullRequest(_ number: Int, _ state: PullRequest.State, additions: Int = 0) -> PullRequest {
        PullRequest(number: number, url: "u/\(number)", state: state, additions: additions, deletions: 1, changedFiles: 1)
    }

    private func review(_ number: Int, draft: Bool = false) -> ReviewEntry {
        ReviewEntry(
            issue: LinearIssueStatus(id: "i", identifier: "A-\(number)", title: "", branchName: "b", state: .init(name: "s", type: "started")),
            pullRequest: ReviewablePullRequest(
                number: number, url: "u/\(number)", title: "", headRefName: "branch-\(number)", isDraft: draft,
                reviewDecision: nil, latestReviews: nil, statusCheckRollup: nil, additions: 7
            )
        )
    }

    @Test("Pull requests come from finished tasks, then from the review list, each once")
    func pullRequestStats() {
        let stats = PullRequestStats.of(
            tasks: [
                task("A-1", .completed, pr: pullRequest(1, .merged, additions: 10)),
                task("A-2", .openPullRequest, pr: pullRequest(2, .open, additions: 20)),
                // Still running, so not yet a finished pull request.
                task("A-3", .running, pr: pullRequest(3, .open)),
                task("A-4", .noPullRequest, pr: pullRequest(4, .closed)),
            ],
            reviews: [review(2), review(5)],
            measure: { branch in (AgentUsage(outputTokens: branch.count), 60) }
        )
        #expect(stats.map(\.url) == ["u/1", "u/2", "u/5"])
        #expect(stats.map(\.merged) == [true, false, false])
        #expect(stats.map(\.additions) == [10, 20, 7])
        #expect(stats[2].usage?.outputTokens == "branch-5".count)
        #expect(stats[2].ciTime == 60)
    }

    // MARK: Rendering

    @Test("Numbers and durations are compact")
    func formatting() {
        #expect(StatusSummary.compact(950) == "950")
        #expect(StatusSummary.compact(12_345) == "12.3k")
        #expect(StatusSummary.compact(123_456) == "123k")
        #expect(StatusSummary.compact(4_500_000) == "4.5M")
        #expect(StatusSummary.compact(1_200_000_000) == "1.2B")
        #expect(StatusSummary.duration(29) == "0m")
        #expect(StatusSummary.duration(14 * 60) == "14m")
        #expect(StatusSummary.duration(2 * 3600 + 5 * 60) == "2h 05m")
        #expect(StatusSummary.duration(3 * 86400 + 4 * 3600) == "3d 04h")
    }

    @Test("Median and mean")
    func statistics() {
        let odd = StatusSummary.Metric(name: "m", values: [5, 1, 3], format: { "\($0)" })
        #expect(odd.median == 3)
        #expect(odd.mean == 3)
        #expect(odd.max == 5)
        #expect(StatusSummary.Metric(name: "m", values: [4, 1, 3, 2], format: { "\($0)" }).median == 2.5)
    }

    @Test("The summary counts sections across workspaces, then gives per pull request and per project figures")
    func rendering() {
        var merged = task("A-1", .completed, pr: pullRequest(1, .merged, additions: 10))
        merged.usage = AgentUsage(inputTokens: 1000, outputTokens: 500, cacheReadTokens: 9000, activeTime: 600)
        merged.ciTime = 120
        let tasks = [merged, task("A-2", .openPullRequest, pr: pullRequest(2, .open, additions: 30)), task("A-3", .queued)]
        let reviews = [review(2), review(6, draft: true)]
        let one = WorkspaceReport(
            name: "one", entries: tasks, reviews: reviews,
            pullRequestStats: PullRequestStats.of(tasks: tasks, reviews: reviews, measure: { _ in (nil, nil) }),
            warnings: []
        )
        // Reviews unknown: the open pull request is counted among the tasks.
        let two = WorkspaceReport(name: "two", entries: [task("B-1", .openPullRequest, pr: pullRequest(9, .open))], warnings: [])
        let empty = WorkspaceReport(name: "three", entries: [], warnings: [])

        #expect(StatusSummary(reports: [one, two, empty]).rendered() == """
        Summary
          Projects             3
          Awaiting review      1
          Draft pull requests  1
          Queued               1
          Open pull requests   1
          Completed            1

          Per pull request (3 from agents: 2 open, 1 merged)
                           total  mean  median   max
            Lines added       47    16      10    30
            Lines removed      2     1       1     1
            Files changed      2     1       1     1
            Tokens          1.5k  1.5k    1.5k  1.5k
            Cache reads     9.0k  9.0k    9.0k  9.0k
            Agent time       10m   10m     10m   10m
            CI time           2m    2m      2m    2m

          All 4 tracked tasks: 1.5k tokens, 9.0k cache reads, 10m agent time, 2m CI time

          By project
                 tasks  PRs  +lines  -lines  tokens  agent time  CI time
            one      3    3      47       2    1.5k         10m       2m
            two      1    0       0       0       -           -        -
        """)
    }
}
