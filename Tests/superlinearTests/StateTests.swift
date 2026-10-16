import Foundation
import Testing
@testable import superlinear

// State decides whether an issue gets an agent, so a mistake here either drops
// work on the floor or starts a second agent on an issue already in flight.
@Suite("State bookkeeping")
struct StateTests {
    @Test("A fresh state has processed nothing")
    func freshState() {
        let state = State()
        #expect(state.isProcessed("SL-1", workspace: "w") == false)
        #expect(state.lastPollTimestamp(workspace: "w") == .distantPast)
    }

    @Test("Marking an issue processed makes it stay processed")
    func markProcessed() {
        var state = State()
        state.markProcessed("SL-1", workspace: "w")
        #expect(state.isProcessed("SL-1", workspace: "w"))
    }

    // The whole point of keying state by workspace: the same issue id arriving
    // from two Linear accounts must be processed once per repository.
    @Test("Workspaces do not share processed ids")
    func workspacesAreIsolated() {
        var state = State()
        state.markProcessed("SL-1", workspace: "one")

        #expect(state.isProcessed("SL-1", workspace: "one"))
        #expect(state.isProcessed("SL-1", workspace: "two") == false)
    }

    @Test("Marking the same issue twice is not an error")
    func markingIsIdempotent() {
        var state = State()
        state.markProcessed("SL-1", workspace: "w")
        state.markProcessed("SL-1", workspace: "w")
        #expect(state.workspaces["w"]?.processedIssueIds.count == 1)
    }

    @Test("The last poll timestamp round-trips per workspace")
    func lastPollRoundTrips() {
        var state = State()
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        state.updateLastPoll(when, workspace: "one")

        #expect(state.lastPollTimestamp(workspace: "one") == when)
        #expect(state.lastPollTimestamp(workspace: "two") == .distantPast)
    }

    @Test("Updating one workspace leaves another untouched")
    func updatesDoNotBleed() {
        var state = State()
        state.markProcessed("SL-1", workspace: "one")
        state.updateLastPoll(Date(timeIntervalSince1970: 1), workspace: "two")

        #expect(state.isProcessed("SL-1", workspace: "one"))
        #expect(state.lastPollTimestamp(workspace: "one") == .distantPast)
    }

    // The daemon writes this file on every poll and reads it at launch, so a
    // round-trip that loses processed ids would reprocess every issue on restart.
    // It goes through the real save and load: an earlier version of this test
    // built its own decoder, and missed that load() read dates differently from
    // how save() wrote them.
    @Test("State survives a save and load through disk")
    func diskRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var state = State()
        state.markProcessed("SL-1", workspace: "w")
        state.updateLastPoll(Date(timeIntervalSince1970: 1_700_000_000), workspace: "w")
        state.recordRun(AgentRun(
            issueId: "SL-2", identifier: "SL-2", branchName: "b", sessionId: "s",
            pid: 42, processStartedAt: Date(timeIntervalSince1970: 1_700_000_100), resumes: 1,
            launchedAt: Date(timeIntervalSince1970: 1_700_000_050),
            review: ReviewRequest(number: 4, url: "https://github.com/o/r/pull/4")
        ), workspace: "w")
        state.awaitMerge(PendingMerge(
            issueId: "SL-3", identifier: "SL-3", branchName: "c",
            reviewsHandledThrough: Date(timeIntervalSince1970: 1_700_000_200)
        ), workspace: "w")
        try state.save(to: url)

        let restored = State.load(from: url)
        #expect(restored.isProcessed("SL-1", workspace: "w"))
        #expect(restored.lastPollTimestamp(workspace: "w").timeIntervalSince1970 == 1_700_000_000)
        #expect(restored.runs(workspace: "w") == state.runs(workspace: "w"))
        #expect(restored.pendingMerges(workspace: "w") == state.pendingMerges(workspace: "w"))
    }

    @Test("A state file from before runs were tracked still loads")
    func legacyStateLoads() throws {
        let json = #"{"workspaces":{"w":{"processedIssueIds":["SL-1"],"lastPollTimestamp":"2023-11-14T22:13:20Z"}}}"#
        let state = try State.decoded(from: Data(json.utf8))
        #expect(state.isProcessed("SL-1", workspace: "w"))
        #expect(state.runs(workspace: "w").isEmpty)
        #expect(state.pendingMerges(workspace: "w").isEmpty)
    }

    @Test("Pending merges are recorded per issue and removed when settled")
    func pendingMergeBookkeeping() {
        var state = State()
        let run = AgentRun(issueId: "SL-1", identifier: "SL-1", branchName: "b", sessionId: "s")
        state.awaitMerge(PendingMerge(run), workspace: "w")
        #expect(state.pendingMerges(workspace: "w") == [
            PendingMerge(issueId: "SL-1", identifier: "SL-1", branchName: "b"),
        ])
        #expect(state.pendingMerges(workspace: "other").isEmpty)

        state.stopAwaitingMerge(issueId: "SL-1", workspace: "w")
        #expect(state.pendingMerges(workspace: "w").isEmpty)
    }

    @Test("A watch takes its review baseline from the run's first launch")
    func pendingMergeReviewBaseline() {
        var run = AgentRun(
            issueId: "SL-1", identifier: "SL-1", branchName: "b", sessionId: "s",
            processStartedAt: Date(timeIntervalSince1970: 200)
        )
        // Runs launched before the first launch was recorded.
        #expect(PendingMerge(run).reviewsHandledThrough == Date(timeIntervalSince1970: 200))
        // A resume moves the process start, but not the first launch.
        run.launchedAt = Date(timeIntervalSince1970: 100)
        #expect(PendingMerge(run).reviewsHandledThrough == Date(timeIntervalSince1970: 100))
    }

    @Test("A watch from before reviews were followed has no review baseline")
    func legacyPendingMergeLoads() throws {
        let json = #"""
        {"workspaces":{"w":{"processedIssueIds":[],"lastPollTimestamp":"2023-11-14T22:13:20Z",
        "pendingMerges":{"SL-1":{"issueId":"SL-1","identifier":"SL-1","branchName":"b"}}}}}
        """#
        let state = try State.decoded(from: Data(json.utf8))
        #expect(state.pendingMerges(workspace: "w") == [
            PendingMerge(issueId: "SL-1", identifier: "SL-1", branchName: "b"),
        ])
        #expect(state.pendingMerges(workspace: "w").first?.reviewsHandledThrough == nil)
    }

    // The review run goes on following the same pull requests, so their links
    // must not be forgotten and linked a second time.
    @Test("Starting a review moves the issue from its merge watch to a run, keeping its links")
    func startReview() {
        var state = State()
        state.awaitMerge(PendingMerge(issueId: "SL-1", identifier: "SL-1", branchName: "b"), workspace: "w")
        state.recordLinkedPullRequest("https://github.com/o/r/pull/1", issueId: "SL-1", workspace: "w")
        let run = AgentRun(
            issueId: "SL-1", identifier: "SL-1", branchName: "b", sessionId: "s",
            review: ReviewRequest(number: 1, url: "https://github.com/o/r/pull/1")
        )
        state.startReview(run, workspace: "w")
        #expect(state.pendingMerges(workspace: "w").isEmpty)
        #expect(state.runs(workspace: "w") == [run])
        #expect(state.linkedPullRequests(issueId: "SL-1", workspace: "w") == ["https://github.com/o/r/pull/1"])
    }

    @Test("Runs are recorded per issue and removed when done")
    func runBookkeeping() {
        var state = State()
        let run = AgentRun(issueId: "SL-1", identifier: "SL-1", branchName: "b", sessionId: "s")
        state.recordRun(run, workspace: "w")
        #expect(state.runs(workspace: "w") == [run])
        #expect(state.runs(workspace: "other").isEmpty)

        state.removeRun(issueId: "SL-1", workspace: "w")
        #expect(state.runs(workspace: "w").isEmpty)
    }

    // Each pull request is linked to its issue once, and the record goes when
    // nothing checks the issue's pull requests any more.
    @Test("Linked pull requests are recorded once and cleared with the merge watch")
    func linkedPullRequests() {
        var state = State()
        state.recordLinkedPullRequest("https://github.com/o/r/pull/1", issueId: "SL-1", workspace: "w")
        state.recordLinkedPullRequest("https://github.com/o/r/pull/1", issueId: "SL-1", workspace: "w")
        state.recordLinkedPullRequest("https://github.com/o/r/pull/2", issueId: "SL-1", workspace: "w")
        #expect(state.linkedPullRequests(issueId: "SL-1", workspace: "w") == [
            "https://github.com/o/r/pull/1", "https://github.com/o/r/pull/2",
        ])
        #expect(state.workspaces["w"]?.linkedPullRequests["SL-1"]?.count == 2)
        #expect(state.linkedPullRequests(issueId: "SL-1", workspace: "other").isEmpty)

        state.stopAwaitingMerge(issueId: "SL-1", workspace: "w")
        #expect(state.linkedPullRequests(issueId: "SL-1", workspace: "w").isEmpty)
    }

    @Test("A state file from before pull requests were linked still loads")
    func legacyStateWithoutLinks() throws {
        let json = #"{"workspaces":{"w":{"processedIssueIds":["SL-1"],"lastPollTimestamp":"2023-11-14T22:13:20Z","inFlight":{},"pendingMerges":{}}}}"#
        let state = try State.decoded(from: Data(json.utf8))
        #expect(state.linkedPullRequests(issueId: "SL-1", workspace: "w").isEmpty)
    }

    @Test("Waiting issues round-trip, are replaced by each poll's, and are absent from older state files")
    func waitingIssues() throws {
        var state = State()
        let blocked = WaitingIssue(identifier: "SL-2", title: "Two", blockers: ["SL-1"])
        let human = WaitingIssue(identifier: "SL-3", title: "Three", labels: ["Spike"])
        state.recordWaiting(blocked: ["id-2": blocked], needsHuman: ["id-3": human], workspace: "w")
        let restored = try State.decoded(from: state.encoded())
        #expect(restored.workspaces["w"]?.blocked == ["id-2": blocked])
        #expect(restored.workspaces["w"]?.needsHuman == ["id-3": human])
        #expect(restored.workspaces["w"]?.waitingIssueIds == ["id-2", "id-3"])

        state.recordWaiting(blocked: [:], needsHuman: ["id-3": human], workspace: "w")
        #expect(state.workspaces["w"]?.blocked.isEmpty == true)

        let json = #"{"workspaces":{"w":{"processedIssueIds":[],"lastPollTimestamp":"2023-11-14T22:13:20Z"}}}"#
        #expect(try State.decoded(from: Data(json.utf8)).workspaces["w"]?.waitingIssueIds == [])
    }

    @Test("Handled issues are the processed, in-flight and watched ones")
    func handledIssues() {
        var state = State()
        state.markProcessed("SL-1", workspace: "w")
        state.recordRun(AgentRun(issueId: "SL-2", identifier: "SL-2", branchName: "b", sessionId: "s"), workspace: "w")
        state.awaitMerge(PendingMerge(issueId: "SL-3", identifier: "SL-3", branchName: "c"), workspace: "w")
        #expect(state.handledIssueIds(workspace: "w") == ["SL-1", "SL-2", "SL-3"])
        #expect(state.handledIssueIds(workspace: "other").isEmpty)
    }
}
