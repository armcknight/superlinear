import Darwin
import Foundation
import Testing
@testable import superlinear

@Suite("AgentRunner")
struct AgentRunnerTests {
    private let run = AgentRun(
        issueId: "id-1", identifier: "SL-1", branchName: "me/sl-1-fix", sessionId: "abc"
    )

    @Test("A new run names its session; a resumed one continues it")
    func workArguments() {
        let start = AgentRunner.workArguments(run: run, mode: .start, promptFile: "p", logFile: "l")
        #expect(start == [
            "work", "start", "--headless", "--prompt-file", "p", "--log-file", "l",
            "--session-id", "abc", "me/sl-1-fix",
        ])
        let resume = AgentRunner.workArguments(run: run, mode: .resume, promptFile: "p", logFile: "l")
        #expect(resume.contains("--resume"))
        #expect(!resume.contains("--session-id"))
    }

    @Test("A review run gets a prompt for its pull request; any other run the issue prompt")
    func prompts() {
        var review = run
        review.review = ReviewRequest(number: 12, url: "https://github.com/o/r/pull/12")
        let prompt = AgentRunner.prompt(for: review)
        #expect(prompt.contains("https://github.com/o/r/pull/12"))
        #expect(prompt.contains("pulls/12/comments"))
        #expect(prompt.contains("Do not reply to the review"))
        #expect(!AgentRunner.prompt(for: run).contains("pull request #"))
        #expect(AgentRunner.prompt(for: run).contains("/armcknight-claude:start"))
    }

    @Test("A review run's prompt lists the reviews and comments that queued it, with the comments' links")
    func promptListsFeedback() {
        var review = run
        review.review = ReviewRequest(
            number: 12, url: "https://github.com/o/r/pull/12",
            feedback: [
                PullRequestFeedback(kind: .review, at: Date(timeIntervalSince1970: 1_791_720_000)),
                PullRequestFeedback(
                    kind: .comment, at: Date(timeIntervalSince1970: 1_791_723_600),
                    url: "https://github.com/o/r/pull/12#issuecomment-1"),
            ])
        let prompt = AgentRunner.prompt(for: review)
        #expect(prompt.contains("- A review submitted at 2026-10-11T12:00:00Z\n"))
        #expect(prompt.contains(
            "- A comment in the conversation made at 2026-10-11T13:00:00Z: https://github.com/o/r/pull/12#issuecomment-1"))
        #expect(prompt.contains("--json reviews,comments"))
        #expect(prompt.contains("Do not reply to the review or post comments on GitHub"))
        // A run from before comments were followed says nothing of them.
        review.review?.feedback = nil
        #expect(!AgentRunner.prompt(for: review).contains("These came in"))
        #expect(AgentRunner.prompt(for: review).contains("commented on it. Your task:"))
    }

    // The order matters: a status means the agent ended, whatever else is true,
    // and a live agent must never be relaunched alongside itself.
    @Test("Recovery prefers a status, then a live process, then the queue")
    func recoveryDecisions() {
        #expect(AgentRunner.recovery(status: 0, running: true, launched: true, resumes: 9) == .finished(0))
        #expect(AgentRunner.recovery(status: nil, running: true, launched: true, resumes: 9) == .adopt)
        #expect(AgentRunner.recovery(status: nil, running: false, launched: false, resumes: 9) == .waiting)
        #expect(AgentRunner.recovery(status: nil, running: false, launched: true, resumes: 0) == .requeue)
        #expect(AgentRunner.recovery(
            status: nil, running: false, launched: true, resumes: AgentRunner.maxResumes
        ) == .abandon)
    }

    @Test("The oldest queued run goes next, and launched ones are skipped")
    func queueOrder() {
        func queued(_ id: String, at seconds: TimeInterval, pid: Int32? = nil) -> (String, AgentRun) {
            ("w", AgentRun(
                issueId: id, identifier: .init(rawValue: id), branchName: "b", sessionId: id, pid: pid,
                queuedAt: Date(timeIntervalSince1970: seconds)
            ))
        }
        let runs = [queued("new", at: 30), queued("running", at: 5, pid: 42), queued("old", at: 10)]
        #expect(AgentRunner.nextQueued(runs)?.1.identifier == "old")
        #expect(AgentRunner.nextQueued([queued("running", at: 5, pid: 42)]) == nil)
    }

    @Test("A run resumes only when Claude saved its session")
    func launchMode() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let runner = AgentRunner(home: home, environment: [:])
        #expect(runner.launchMode(for: run) == .start)

        let project = "\(home)/.claude/projects/-x"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(project)/abc.jsonl", contents: Data())
        #expect(runner.launchMode(for: run) == .resume)
    }

    @Test("A live process is recognised by its pid and start time")
    func recognisesLiveProcess() throws {
        let pid = getpid()
        let started = try #require(AgentRunner.startTime(of: pid))

        var live = run
        live.pid = pid
        live.processStartedAt = started
        #expect(AgentRunner.isRunning(live))

        // The same pid with another start time is a different process.
        var reused = live
        reused.processStartedAt = started.addingTimeInterval(-3600)
        #expect(!AgentRunner.isRunning(reused))

        var unlaunched = run
        unlaunched.pid = nil
        #expect(!AgentRunner.isRunning(unlaunched))
    }

    @Test("A session can be resumed only when Claude saved its transcript")
    func findsTranscripts() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let runner = AgentRunner(home: home, environment: [:])
        #expect(!runner.claudeSessionExists("abc"))

        let project = "\(home)/.claude/projects/-Users-me-repo-worktrees-x"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(project)/abc.jsonl", contents: Data())
        #expect(runner.claudeSessionExists("abc"))
        #expect(!runner.claudeSessionExists("other"))
    }

    @Test("The latest Claude session of a worktree is found by its project directory")
    func latestClaudeSession() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let runner = AgentRunner(home: home, environment: [:])
        let worktree = "/Users/me/repo/worktrees/linear/spl-1-a.b"
        #expect(AgentRunner.claudeProjectName(worktree) == "-Users-me-repo-worktrees-linear-spl-1-a-b")
        #expect(runner.latestClaudeSession(inWorktree: worktree) == nil)

        let project = "\(home)/.claude/projects/-Users-me-repo-worktrees-linear-spl-1-a-b"
        let fm = FileManager.default
        try fm.createDirectory(atPath: "\(project)/new", withIntermediateDirectories: true)
        fm.createFile(atPath: "\(project)/old.jsonl", contents: Data())
        fm.createFile(atPath: "\(project)/new.jsonl", contents: Data())
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: "\(project)/old.jsonl")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: "\(project)/new.jsonl")
        #expect(runner.latestClaudeSession(inWorktree: worktree) == "new")
    }

    @Test("The usage limit is read from the end of an issue's agent log")
    func usageLimitFromLog() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let runner = AgentRunner(home: home, environment: [:])
        let logs = runner.logsDirectory
        try FileManager.default.createDirectory(atPath: logs, withIntermediateDirectories: true)
        try "You've hit your session limit · resets 4:30pm (America/Anchorage)\n".write(
            toFile: "\(logs)/SPL-1.log", atomically: true, encoding: .utf8)
        try "All done.\n".write(toFile: "\(logs)/SPL-2.log", atomically: true, encoding: .utf8)
        #expect(runner.usageLimitHit(identifier: "SPL-1", now: Date()) != nil)
        #expect(runner.usageLimitHit(identifier: "SPL-2", now: Date()) == nil)
        #expect(runner.usageLimitHit(identifier: "SPL-3", now: Date()) == nil)
    }

    // Runs the real wrapper against a stand-in `work`, to check that the exit
    // status reaches both the status file and the exit handler.
    @Test("A launched agent reports work's exit status")
    func launchReportsStatus() async throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let bin = "\(home)/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try "#!/bin/sh\necho \"work $*\"\necho \"model $ANTHROPIC_MODEL\"\nexit 3\n".write(toFile: "\(bin)/work", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(bin)/work")

        let runner = AgentRunner(home: home, environment: ["PATH": "\(bin):/usr/bin:/bin"])
        let status: Int32? = try await withCheckedThrowingContinuation { continuation in
            do {
                let (launched, _) = try runner.launch(run, mode: .start, repoPath: home, apiKey: "key") { status in
                    continuation.resume(returning: status)
                }
                #expect(launched.pid != nil)
                #expect(launched.processStartedAt != nil)
            } catch {
                continuation.resume(throwing: error)
            }
        }

        #expect(status == 3)
        #expect(AgentRunner.readStatus(atPath: runner.statusFile(for: run)) == 3)
        let workLog = try String(contentsOfFile: runner.workLog(for: run), encoding: .utf8)
        #expect(workLog.contains("--session-id abc me/sl-1-fix"))
        #expect(workLog.contains("model opus"))
        let prompt = try String(contentsOfFile: runner.promptFile(for: run), encoding: .utf8)
        #expect(prompt.contains("/armcknight-claude:start"))

        runner.cleanUp(run)
        #expect(!FileManager.default.fileExists(atPath: runner.statusFile(for: run)))
    }

    private func temporaryDirectory() throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }
}
