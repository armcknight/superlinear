import Foundation
import Testing
@testable import superlinear

// Project-management sessions run on Fable. Its usage limit is its own, so
// when it is used up they run on Opus, and on Fable again once it resets.
@Suite("Planning model")
struct PlanningModelTests {
    private let now = ISO8601DateFormatter().date(from: "2026-10-16T10:00:00Z")!

    private func hit(resetIn interval: TimeInterval?) -> ClaudeUsageLimit.Hit {
        ClaudeUsageLimit.Hit(resetAt: interval.map { .init(rawValue: now.addingTimeInterval($0)) })
    }

    @Test("Sessions run on Fable, and on Opus while its limit is used up")
    func current() {
        #expect(PlanningModel.current(limit: nil, now: now) == .fable)
        let limit = FableLimit(hit: hit(resetIn: 3600), now: now)
        #expect(PlanningModel.current(limit: limit, now: now) == .opus)
        #expect(PlanningModel.current(limit: limit, now: now.addingTimeInterval(3600)) == .fable)
        #expect(PlanningModel.fable.arguments == ["--model", "fable"])
    }

    @Test("A limit with no reset time lasts the fallback delay")
    func fallbackDelay() {
        let limit = FableLimit(hit: hit(resetIn: nil), now: now)
        #expect(limit.until.rawValue == now.addingTimeInterval(ClaudePause.fallbackDelay))
        #expect(FableLimit(hit: hit(resetIn: -60), now: now).until.rawValue == now.addingTimeInterval(ClaudePause.fallbackDelay))
    }

    @Test("The state remembers the limit, moves it to a later reset, and forgets it once it resets")
    func state() throws {
        var state = State()
        #expect(state.planningModel(now: now) == .fable)

        state.recordFableLimit(hit(resetIn: 3600), now: now)
        #expect(state.planningModel(now: now) == .opus)
        // A second hit with no reset time keeps the known one.
        state.recordFableLimit(hit(resetIn: nil), now: now.addingTimeInterval(60))
        #expect(state.fableLimit?.until.rawValue == now.addingTimeInterval(3600))
        state.recordFableLimit(hit(resetIn: 7200), now: now.addingTimeInterval(60))
        #expect(state.fableLimit?.since == now)
        #expect(state.fableLimit?.until.rawValue == now.addingTimeInterval(7200))

        // It survives a restart.
        let reloaded = try State.decoded(from: state.encoded())
        #expect(reloaded.fableLimit == state.fableLimit)

        #expect(state.planningModel(now: now.addingTimeInterval(7200)) == .fable)
        #expect(state.fableLimit == nil)
    }

    @Test("A state file from before the limit was kept still loads")
    func oldState() throws {
        let state = try State.decoded(from: Data(#"{"workspaces": {}}"#.utf8))
        #expect(state.fableLimit == nil)
    }

    @Test("A planning job written before the model was kept still loads")
    func oldRun() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let run = try decoder.decode(
            PlanningRun.self, from: Data(#"{"sessionId": "s1", "startedAt": "2026-10-16T10:00:00Z", "worktreePath": "/repo", "resumes": 0}"#.utf8))
        #expect(run.model == nil)
    }

    @Test("Fable's own limit message is found")
    func fableMessage() {
        let found = ClaudeUsageLimit.hit(in: "Fable weekly limit reached ∙ resets Mon 9am", now: now, timeZone: TimeZone(identifier: "UTC")!)
        #expect(found?.resetAt?.rawValue == ISO8601DateFormatter().date(from: "2026-10-19T09:00:00Z"))
        #expect(ClaudeUsageLimit.hit(in: "You've hit your Fable limit · resets 3pm", now: now, timeZone: .current) != nil)
    }

    @Test("The planning job's log tells the limit it stopped at")
    func planningLog() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = PlanningRunner(home: home.path, environment: [:])
        #expect(runner.usageLimitHit(workspace: "w", now: now) == nil)
        try FileManager.default.createDirectory(atPath: runner.logsDirectory, withIntermediateDirectories: true)
        try "Reading the code\nFable weekly limit reached ∙ resets 3pm\n".write(toFile: runner.log(workspace: "w"), atomically: true, encoding: .utf8)
        #expect(runner.usageLimitHit(workspace: "w", now: now) != nil)
    }

    @Test("Comment sessions run on the model they are given")
    func commentArguments() {
        let arguments = CommentSessionRunner.claudeArguments(sessionId: "s1", model: .opus)
        #expect(arguments == ["claude", "-p", "--session-id", "s1", "--model", "opus", "--allowedTools", CommentSessionRunner.allowedTools])
    }

    @Test("Status shows the limit while it holds")
    func status() {
        var state = State()
        state.fableLimit = FableLimit(hit: hit(resetIn: 3600), now: now)
        let lines = StatusCommand.pauseLines(state: state, workspaces: [], now: now)
        #expect(lines.count == 1)
        #expect(lines[0].hasPrefix("Fable usage limit: planning and comment answers run on opus until "))
        #expect(StatusCommand.pauseLines(state: state, workspaces: [], now: now.addingTimeInterval(3600)).isEmpty)
    }
}
