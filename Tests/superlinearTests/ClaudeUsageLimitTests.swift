import Foundation
import Testing
@testable import superlinear

// Claude stops every session at the plan's usage limit, and has said so in
// several ways. Each form must be found, with its reset time when it gives
// one, and nothing else must be taken for it.
@Suite("Claude usage limit")
struct ClaudeUsageLimitTests {
    private let utc = TimeZone(identifier: "UTC")!
    /// A Friday, 10:00 UTC.
    private let now = ISO8601DateFormatter().date(from: "2026-10-16T10:00:00Z")!

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func reset(_ output: String) -> Date?? {
        ClaudeUsageLimit.hit(in: output, now: now, timeZone: utc).map { $0.resetAt?.rawValue }
    }

    private func resetTime(_ date: Date) -> ClaudeUsageLimit.ResetTime { .init(rawValue: date) }

    @Test("The pipe form gives its reset as a Unix time")
    func pipeForm() {
        #expect(reset("Claude AI usage limit reached|1792000000") == .some(Date(timeIntervalSince1970: 1_792_000_000)))
        #expect(reset("Claude AI usage limit reached") == .some(nil))
        let json = #"{"type":"result","subtype":"success","is_error":true,"result":"Claude AI usage limit reached|1792000000"}"#
        #expect(reset(json) == .some(Date(timeIntervalSince1970: 1_792_000_000)))
    }

    @Test("\"You've hit your limit\", with and without a time and a time zone")
    func hitYourLimit() {
        // 02:00 in Anchorage, which is UTC-8 in October.
        #expect(reset("You've hit your session limit · resets 2:30am (America/Anchorage)") == .some(date("2026-10-16T10:30:00Z")))
        // It is 03:00 in Los Angeles, so 02:00 is tomorrow's.
        #expect(reset("You’ve hit your limit · resets 2am (America/Los_Angeles)") == .some(date("2026-10-17T09:00:00Z")))
        #expect(reset("You've hit your weekly limit · resets 3pm") == .some(date("2026-10-16T15:00:00Z")))
        #expect(reset("You've hit your limit") == .some(nil))
    }

    @Test("\"Limit reached\", with a time, a weekday or a date")
    func limitReached() {
        #expect(reset("5-hour limit reached ∙ resets 3pm") == .some(date("2026-10-16T15:00:00Z")))
        #expect(reset("Opus weekly limit reached ∙ resets Mon 9am") == .some(date("2026-10-19T09:00:00Z")))
        #expect(reset("Weekly limit reached ∙ resets Oct 20, 3:30pm") == .some(date("2026-10-20T15:30:00Z")))
        #expect(reset("Claude usage limit reached. Your limit will reset at 3pm (America/Los_Angeles).")
            == .some(date("2026-10-16T22:00:00Z")))
        #expect(reset("Claude usage limit reached.") == .some(nil))
    }

    @Test("Only the end of the output counts, and only a line that starts with the message")
    func notTheLimit() {
        #expect(reset("All done.\nThe GitHub GraphQL rate limit was exceeded, so I used REST.") == nil)
        #expect(reset("GitHub API rate limit reached") == nil)
        #expect(reset("I handled the case \"You've hit your limit\" in the parser.") == nil)
        #expect(reset("You've hit your session limit · resets 3pm\n1\n2\n3\nDone") == nil)
        #expect(reset("You've hit your session limit · resets 3pm\n\nShell cwd was reset to /tmp") != nil)
        #expect(reset("") == nil)
    }

    @Test("The pause lasts until the reset, or an hour when Claude gives none")
    func pauseLength() {
        let timed = ClaudePause(hit: .init(resetAt: resetTime(now.addingTimeInterval(7200))), now: now)
        #expect(timed.until.rawValue == now.addingTimeInterval(7200))
        #expect(timed.nextCheckAt == now.addingTimeInterval(ClaudePause.checkInterval))
        let untimed = ClaudePause(hit: .init(resetAt: nil), now: now)
        #expect(untimed.until.rawValue == now.addingTimeInterval(ClaudePause.fallbackDelay))
        #expect(!untimed.isOver(now: now.addingTimeInterval(3599)))
        #expect(untimed.isOver(now: now.addingTimeInterval(3600)))
    }

    @Test("The 15-minute check resumes early when the session answers")
    func checkResumesEarly() {
        let pause = ClaudePause(hit: .init(resetAt: resetTime(now.addingTimeInterval(4 * 3600))), now: now)
        #expect(!pause.checkDue(now: now.addingTimeInterval(14 * 60)))
        #expect(pause.checkDue(now: now.addingTimeInterval(15 * 60)))
        let check = ClaudePause.reading("ok\n", status: 0, now: now)
        #expect(check == .lifted)
        #expect(pause.after(check, now: now.addingTimeInterval(15 * 60)) == nil)
    }

    @Test("The 15-minute check keeps the pause, with the new reset time, when the limit holds")
    func checkKeepsPause() {
        let pause = ClaudePause(hit: .init(resetAt: resetTime(now.addingTimeInterval(4 * 3600))), now: now)
        let later = now.addingTimeInterval(15 * 60)
        let check = ClaudePause.reading("You've hit your limit · resets 5pm\n", status: 1, now: later)
        guard case .limited = check else {
            Issue.record("expected the limit, got \(check)")
            return
        }
        let kept = pause.after(.limited(.init(resetAt: resetTime(now.addingTimeInterval(7 * 3600)))), now: later)
        #expect(kept?.until.rawValue == now.addingTimeInterval(7 * 3600))
        // A reset time already past does not shorten the pause.
        #expect(pause.after(.limited(.init(resetAt: resetTime(now))), now: later)?.until == pause.until)
        #expect(kept?.since == now)
        #expect(kept?.nextCheckAt == later.addingTimeInterval(ClaudePause.checkInterval))
        // A message with no time keeps the reset time it had.
        #expect(pause.after(.limited(.init(resetAt: nil)), now: later)?.until == pause.until)
        // A check that fails for another reason keeps the pause, and checks again later.
        let failed = ClaudePause.reading("network down", status: 1, now: later)
        #expect(failed == .failed("`claude` exited 1: network down"))
        #expect(pause.after(failed, now: later)?.until == pause.until)
        #expect(pause.after(failed, now: later)?.nextCheckAt == later.addingTimeInterval(ClaudePause.checkInterval))
    }

    @Test("The check is one small session with no tools")
    func checkArguments() {
        #expect(ClaudePause.checkArguments.starts(with: ["claude", "-p", "--tools", ""]))
    }

    @Test("A session that ends at the limit is found from the end of its log")
    func runLog() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let runner = AgentRunner(home: home, environment: [:])
        let run = AgentRun(issueId: "i", identifier: "SPL-1", branchName: "b", sessionId: "s")
        try FileManager.default.createDirectory(atPath: runner.logsDirectory, withIntermediateDirectories: true)
        #expect(runner.usageLimitHit(for: run, now: now) == nil)
        let filler = String(repeating: "work\n", count: 4000)
        try (filler + "Claude AI usage limit reached|1792000000\n").write(
            toFile: runner.agentLog(for: run), atomically: true, encoding: .utf8)
        #expect(runner.usageLimitHit(for: run, now: now)?.resetAt?.rawValue == Date(timeIntervalSince1970: 1_792_000_000))
        try (filler + "Opened the pull request.\n").write(toFile: runner.agentLog(for: run), atomically: true, encoding: .utf8)
        #expect(runner.usageLimitHit(for: run, now: now) == nil)
    }

    @Test("A stopped session is interrupted, not failed: it keeps its session, place and counts")
    func stoppedRun() {
        var run = AgentRun(
            issueId: "i", identifier: "SPL-1", branchName: "b", sessionId: "session-1", pid: 42,
            processStartedAt: now, resumes: 1, queuedAt: now, launchFailures: 2, launchedAt: now)
        let stopped = run.stoppedByUsageLimit()
        #expect(stopped.isQueued)
        #expect(stopped.usageLimited == true)
        #expect(stopped.sessionId == "session-1")
        #expect(stopped.resumes == 1)
        #expect(stopped.launchFailures == 2)
        #expect(stopped.queuedAt == now)
        #expect(!stopped.isFresh)
        // A second limit right after the resume changes nothing more.
        run = stopped
        run.pid = 43
        run.usageLimited = nil
        #expect(run.stoppedByUsageLimit() == stopped)
    }

    @Test("Interrupted sessions resume first, ahead of older and standup-ranked runs")
    func interruptedFirst() {
        func run(_ id: String, at seconds: TimeInterval, limited: Bool = false) -> (String, AgentRun) {
            var run = AgentRun(
                issueId: id, identifier: .init(rawValue: id), branchName: "b", sessionId: id,
                queuedAt: Date(timeIntervalSince1970: seconds))
            if limited { run = run.stoppedByUsageLimit() }
            return ("w", run)
        }
        let runs = [run("old", at: 1), run("ranked", at: 2), run("limited", at: 50, limited: true)]
        let next = AgentRunner.nextQueued(runs) { _, run in run.issueId == "ranked" ? 0 : nil }
        #expect(next?.1.identifier == "limited")
        #expect(next?.1.sessionId == "limited")
        #expect(AgentRunner.nextQueued(Array(runs.prefix(2))) { _, run in run.issueId == "ranked" ? 0 : nil }?.1.identifier == "ranked")
    }

    @Test("The pause is kept in the state file, and lifted by resume")
    func stateFile() throws {
        var state = State()
        state.claudePause = ClaudePause(hit: .init(resetAt: nil), now: now)
        state.recordRun(
            AgentRun(issueId: "i", identifier: "SPL-1", branchName: "b", sessionId: "s").stoppedByUsageLimit(),
            workspace: "w")
        let decoded = try State.decoded(from: try state.encoded())
        #expect(decoded.claudePause == state.claudePause)
        // The reset time is a plain date in the file, like the others.
        let file = try #require(try JSONSerialization.jsonObject(with: state.encoded()) as? [String: Any])
        let pause = try #require(file["claudePause"] as? [String: Any])
        #expect(pause["until"] is String && pause["since"] is String)
        #expect(decoded.queuedRuns.first?.usageLimited == true)
        #expect(try State.decoded(from: Data(#"{"workspaces":{}}"#.utf8)).claudePause == nil)
        var lifted = decoded
        let first = lifted.liftClaudePause()
        let second = lifted.liftClaudePause()
        #expect(first)
        #expect(lifted.claudePause == nil)
        #expect(!second)
    }

    @Test("superlinear resume signals a running daemon, or lifts the pause in the file")
    func resumeCommand() {
        var state = State()
        let stopped = DaemonStatus(running: false)
        var saved: State?
        let (none, noneStatus) = ResumeCommand.resume(state: state, daemon: stopped, signal: { _ in true }, save: { saved = $0 }, now: now)
        #expect(none.contains("not paused"))
        #expect(noneStatus == 0)
        #expect(saved == nil)

        state.claudePause = ClaudePause(hit: .init(resetAt: nil), now: now)
        var signalled: Int32?
        let running = DaemonStatus(lockPid: 321, running: true)
        let (asked, askedStatus) = ResumeCommand.resume(
            state: state, daemon: running, signal: { signalled = $0; return true }, save: { saved = $0 }, now: now)
        #expect(signalled == 321)
        #expect(asked.contains("Asked the daemon"))
        #expect(askedStatus == 0)
        #expect(saved == nil)

        let (lifted, liftedStatus) = ResumeCommand.resume(
            state: state, daemon: stopped, signal: { _ in Issue.record("signalled"); return true }, save: { saved = $0 }, now: now)
        #expect(lifted.contains("Lifted the Claude pause"))
        #expect(liftedStatus == 0)
        #expect(saved != nil && saved?.claudePause == nil)
    }

    @Test("Status shows the pause with its next check and the sessions waiting")
    func statusLine() {
        var state = State()
        state.claudePause = ClaudePause(
            since: now, until: resetTime(now.addingTimeInterval(3600)), nextCheckAt: now.addingTimeInterval(900))
        for id in ["a", "b"] {
            state.recordRun(AgentRun(issueId: id, identifier: .init(rawValue: id), branchName: id, sessionId: id), workspace: "w")
        }
        let lines = StatusCommand.pauseLines(state: state, workspaces: ["w"], now: now)
        #expect(lines.count == 1)
        #expect(lines[0].hasPrefix("Claude usage limit: paused until "))
        #expect(lines[0].contains("(next check "))
        #expect(lines[0].hasSuffix("2 sessions waiting"))
        #expect(StatusCommand.pauseLines(state: state, workspaces: ["w"], now: now.addingTimeInterval(3600)).isEmpty)
    }
}
