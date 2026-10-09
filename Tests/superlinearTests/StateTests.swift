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
            pid: 42, processStartedAt: Date(timeIntervalSince1970: 1_700_000_100), resumes: 1
        ), workspace: "w")
        try state.save(to: url)

        let restored = State.load(from: url)
        #expect(restored.isProcessed("SL-1", workspace: "w"))
        #expect(restored.lastPollTimestamp(workspace: "w").timeIntervalSince1970 == 1_700_000_000)
        #expect(restored.runs(workspace: "w") == state.runs(workspace: "w"))
    }

    @Test("A state file from before runs were tracked still loads")
    func legacyStateLoads() throws {
        let json = #"{"workspaces":{"w":{"processedIssueIds":["SL-1"],"lastPollTimestamp":"2023-11-14T22:13:20Z"}}}"#
        let state = try State.decoded(from: Data(json.utf8))
        #expect(state.isProcessed("SL-1", workspace: "w"))
        #expect(state.runs(workspace: "w").isEmpty)
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
}
