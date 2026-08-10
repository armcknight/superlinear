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
    @Test("State survives an encode/decode round trip")
    func codableRoundTrip() throws {
        var state = State()
        state.markProcessed("SL-1", workspace: "w")
        state.updateLastPoll(Date(timeIntervalSince1970: 1_700_000_000), workspace: "w")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let restored = try decoder.decode(State.self, from: encoder.encode(state))

        #expect(restored.isProcessed("SL-1", workspace: "w"))
        #expect(restored.lastPollTimestamp(workspace: "w").timeIntervalSince1970 == 1_700_000_000)
    }
}
