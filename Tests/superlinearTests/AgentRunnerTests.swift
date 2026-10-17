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

    @Test("A GitHub issue's agent reads it from GitHub and closes it from its pull request")
    func gitHubPrompt() {
        var gitHub = run
        gitHub.gitHubIssue = 12
        let prompt = AgentRunner.prompt(for: gitHub)
        #expect(prompt.contains("gh issue view 12"))
        #expect(prompt.contains("Closes #12"))
        #expect(!AgentRunner.prompt(for: run).contains("gh issue view"))
        // The same rules as every other agent.
        #expect(prompt.contains(followUpInstructions))
        #expect(prompt.contains("GitHub's spending limit"))
    }

    @Test("A review run on a GitHub issue reads the issue from GitHub, not Linear")
    func gitHubReviewPrompt() {
        var review = run
        review.gitHubIssue = 7
        review.review = ReviewRequest(number: 12, url: "https://github.com/o/r/pull/12")
        let prompt = AgentRunner.prompt(for: review)
        #expect(prompt.contains("pulls/12/comments"))
        #expect(prompt.contains("gh issue view 7"))
        #expect(!prompt.contains("linctl"))
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

    // Runs the real wrapper against a stand-in `work`, to check that the exit
    // status reaches both the status file and the exit handler.
    @Test("A launched agent reports work's exit status")
    func launchReportsStatus() async throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let bin = "\(home)/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try "#!/bin/sh\necho \"work $*\"\nexit 3\n".write(toFile: "\(bin)/work", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(bin)/work")

        let runner = AgentRunner(home: home, environment: ["PATH": "\(bin):/usr/bin:/bin"])
        let status: Int32? = try await withCheckedThrowingContinuation { continuation in
            do {
                let (launched, _) = try runner.launch(run, mode: .start, repoPath: home) { status in
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
