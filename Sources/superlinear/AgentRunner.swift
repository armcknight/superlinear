import Darwin
import Foundation

/// What every agent does with work it finds outside its issue. The daemon
/// reads the file when the agent exits and proposes each entry.
let followUpInstructions = """
When you find a bug or missing work outside this issue, do not fix it and do not create Linear \
issues. Instead, add an entry to the JSON array in `\(FollowUpFile.directory)/\(FollowUpFile.name)` at \
the root of the worktree, and create the file and its directory if they do not exist. Git ignores \
the file; do not commit it. Each entry is an object with these keys:
- `title`: a short title for a new issue.
- `description`: what is wrong or missing, and why it matters.
- `kind`: one of \(FollowUp.Kind.allCases.map { "`\($0.rawValue)`" }.joined(separator: ", ")).
- `evidence`: the file and line, the failing command, or a log excerpt that shows it.
- `relatedIssue`: optional; the identifier, such as `ABC-12`, of an issue it blocks or relates to.
When you exit, superlinear proposes a Linear issue for each entry.
"""

private let autonomousPrompt = """
You are working autonomously on a Linear issue. Do not ask for confirmation at any step — \
proceed through the entire workflow without pausing.

Your task:
1. Run /armcknight-claude:start to read the issue details, create a work plan, and set the issue to "In Progress".
2. Implement all the changes needed to complete the issue, following the plan from /armcknight-claude:start.
3. When implementation is complete, run /armcknight-claude:commit to stage and commit your changes.
4. Run /armcknight-claude:pr --autonomous to open a pull request without opening a browser, monitor CI until it passes, and address any review comments.

Work autonomously. Do not pause to ask questions. If you encounter ambiguity, make a reasonable \
decision and document it in the PR description.

If CI jobs did not start because of GitHub's spending limit or a billing problem, that is not a \
failure to fix: do not change code for it, stop monitoring CI, and say so in the pull request description.

\(followUpInstructions)
"""

/// The prompt for an agent on GitHub issue `number`, which has no Linear
/// issue to read or move.
func gitHubIssuePrompt(number: Int) -> String {
    """
    You are working autonomously on GitHub issue #\(number) of this repository. There is no Linear \
    issue for it. Do not ask for confirmation at any step — proceed through the entire workflow \
    without pausing.

    Your task:
    1. Run `gh issue view \(number) --comments` to read the issue and its discussion, and create a work plan.
    2. Implement all the changes needed to resolve the issue, following your plan.
    3. When implementation is complete, run /armcknight-claude:commit to stage and commit your changes.
    4. Run /armcknight-claude:pr --autonomous to open a pull request without opening a browser, monitor CI until it passes, and address any review comments. There is no Linear issue to read or update: describe the pull request from the GitHub issue, and put `Closes #\(number)` in its description.

    Never comment on the issue. Work autonomously. Do not pause to ask questions. If you encounter \
    ambiguity, make a reasonable decision and document it in the PR description.
    """
}

/// The prompt for a run that answers a review on the pull request an earlier
/// agent opened. It starts a new Claude session, so it says everything itself.
/// `gitHubIssue` is the GitHub issue's number, when the run comes from GitHub.
func reviewPrompt(for review: ReviewRequest, gitHubIssue: Int? = nil) -> String {
    let source = gitHubIssue.map { "GitHub issue #\($0)" } ?? "a Linear issue"
    let readIssue = gitHubIssue.map { "Read the GitHub issue with `gh issue view \($0) --comments`" }
        ?? "Read the Linear issue for this branch with `direnv exec . linctl issue get`"
    return """
    You are working autonomously on \(source) whose pull request has been reviewed. Do not \
    ask for confirmation at any step — proceed through the entire workflow without pausing.

    An earlier agent already implemented the issue on this branch and opened pull request \
    #\(review.number): \(review.url)

    The maintainer has since reviewed it. Your task:
    1. \(readIssue), and the branch's \
    commits against the base branch, to learn what was done.
    2. Read every review on the pull request and every comment in them, including the inline \
    comments on lines of code: `gh pr view \(review.number) --json reviews` and \
    `gh api repos/{owner}/{repo}/pulls/\(review.number)/comments`. Work out which review points \
    are not yet addressed by the commits on the branch.
    3. Implement whatever is needed to satisfy each of those points. If a point asks a question \
    rather than for a change, answer it in the pull request description.
    4. Run /armcknight-claude:commit to stage and commit your changes, then push the branch.
    5. Update the pull request description with `gh pr edit` if the changes make it out of date.
    6. Monitor CI until all checks pass, fixing breakages as they come.

    If CI jobs did not start because of GitHub's spending limit or a billing problem, that is not a \
    failure to fix: do not change code for it, stop monitoring CI, and say so in the pull request description.

    Do not reply to the review or post comments on GitHub. If every point is already addressed, \
    stop. If you encounter ambiguity, make a reasonable decision and document it in the pull \
    request description.

    \(followUpInstructions)
    """
}

/// The prompt for a run that merges the base branch into the branch of a pull
/// request that conflicts with it, so the pull request can merge again.
/// `gitHubIssue` is the GitHub issue's number, when the run comes from GitHub.
func conflictPrompt(for conflict: ConflictRequest, gitHubIssue: Int? = nil) -> String {
    let base = conflict.baseBranch
    let source = gitHubIssue.map { "GitHub issue #\($0)" } ?? "a Linear issue"
    let readIssue = gitHubIssue.map { "Read the GitHub issue with `gh issue view \($0) --comments`" }
        ?? "Read the Linear issue for this branch with `direnv exec . linctl issue get`"
    return """
    You are working autonomously on \(source) whose pull request no longer merges cleanly. Do \
    not ask for confirmation at any step — proceed through the entire workflow without pausing.

    An earlier agent already implemented the issue on this branch and opened pull request \
    #\(conflict.number): \(conflict.url)

    Its base branch, `\(base)`, has since moved on, and GitHub reports that the pull request \
    conflicts with it. Your task:
    1. \(readIssue), and the branch's \
    commits against the base branch, to learn what the branch does.
    2. Run `git fetch origin \(base)`, then `git merge origin/\(base)`. Do not rebase and do not \
    force-push: the pull request's history must stay as it is.
    3. Resolve every conflict so that the result keeps both the branch's changes and the changes on \
    `\(base)`. Read the commits on `\(base)` that touch the conflicting files to learn what they \
    intend. Where the two cannot both be kept, keep the behavior of `\(base)` and adapt the \
    branch's changes to it.
    4. Build and run the tests, and fix what the merge broke. Commit the merge, and any fixes after it.
    5. Push the branch.
    6. Update the pull request description with `gh pr edit` if the merge makes it out of date.
    7. Monitor CI until all checks pass, fixing breakages as they come.

    If CI jobs did not start because of GitHub's spending limit or a billing problem, that is not a \
    failure to fix: do not change code for it, stop monitoring CI, and say so in the pull request description.

    Do not post comments on GitHub. If the branch already merges cleanly with `origin/\(base)`, \
    stop. If you encounter ambiguity, make a reasonable decision and document it in the pull \
    request description.

    \(followUpInstructions)
    """
}

private let resumePrompt = """
You were interrupted partway through the task above. Work out where you stopped — check the \
worktree's git status and log, the issue's state in Linear or GitHub, and whether a pull request exists and \
how its CI is doing — then carry on with the remaining steps. Do not redo finished steps. If \
everything is already done, stop.
"""

/// How a run's agent is launched.
enum LaunchMode: Equatable {
    /// A new Claude session with the run's session ID and the full prompt.
    case start
    /// Continues the run's existing Claude session.
    case resume
}

/// What a restarted daemon does with a run it finds in the state file.
enum Recovery: Equatable {
    /// The agent finished while the daemon was down, with this status.
    case finished(Int32)
    /// The agent is still running. Wait for it.
    case adopt
    /// The run never launched. Leave it in the queue.
    case waiting
    /// The agent was interrupted. Put it back in the queue, to be resumed when
    /// a slot is free.
    case requeue
    /// The agent was interrupted too many times. Stop trying.
    case abandon
}

/// Launches agents and inspects the traces they leave, so the daemon can track
/// them across its own restarts.
///
/// Each agent runs `work start --headless` under a small `sh` wrapper that
/// writes `work`'s exit status to a file when it ends. Foundation starts the
/// wrapper in its own process group, so it outlives the daemon: a restart,
/// such as a Homebrew upgrade, does not stop agents in flight. The status file
/// tells a later daemon how an agent it was not around to see ended.
struct AgentRunner: Sendable {
    /// Resumes after which a run is abandoned, so an agent that keeps dying
    /// does not keep being restarted.
    static let maxResumes = 3

    let home: String
    /// The environment agents launch with. `work` and `claude` are found
    /// through its PATH.
    let environment: [String: String]

    init(
        home: String = Paths.home,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.home = home
        self.environment = environment
    }

    var runsDirectory: String { "\(home)/.local/share/superlinear/runs" }
    var logsDirectory: String { "\(home)/.local/share/superlinear/logs" }

    func statusFile(for run: AgentRun) -> String { "\(runsDirectory)/\(run.sessionId).status" }
    func promptFile(for run: AgentRun) -> String { "\(runsDirectory)/\(run.sessionId).prompt" }
    /// Claude's output, written by `work`.
    func agentLog(for run: AgentRun) -> String { "\(logsDirectory)/\(run.identifier).log" }
    /// The output of `work` itself, appended across launches.
    func workLog(for run: AgentRun) -> String { workLog(identifier: run.identifier) }
    func workLog(identifier: LinearIssue.Identifier) -> String { "\(logsDirectory)/\(identifier).work.log" }

    // MARK: Launching

    static func workArguments(
        run: AgentRun, mode: LaunchMode, promptFile: String, logFile: String
    ) -> [String] {
        let session = mode == .resume ? "--resume" : "--session-id"
        return [
            "work", "start", "--headless",
            "--prompt-file", promptFile,
            "--log-file", logFile,
            session, run.sessionId,
            run.branchName,
        ]
    }

    /// Runs `work` and leaves its exit status in `$SUPERLINEAR_STATUS_FILE`,
    /// written through a temporary file so a reader never sees half of it.
    static let wrapperScript = #"""
    "$@"
    status=$?
    printf '%s\n' "$status" > "$SUPERLINEAR_STATUS_FILE.tmp" && mv "$SUPERLINEAR_STATUS_FILE.tmp" "$SUPERLINEAR_STATUS_FILE"
    """#

    /// Starts the agent for `run` in `repoPath` and calls `onExit` with its
    /// status — nil when it left none — once it ends. Returns the run with the
    /// launched process recorded.
    func launch(
        _ run: AgentRun, mode: LaunchMode, repoPath: String,
        onExit: @escaping @Sendable (Int32?) -> Void
    ) throws -> (AgentRun, Process) {
        let fm = FileManager.default
        try fm.createDirectory(atPath: runsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: logsDirectory, withIntermediateDirectories: true)
        try? fm.removeItem(atPath: statusFile(for: run))

        let prompt = mode == .resume ? resumePrompt : Self.prompt(for: run)
        try prompt.write(toFile: promptFile(for: run), atomically: true, encoding: .utf8)

        if !fm.fileExists(atPath: workLog(for: run)) {
            fm.createFile(atPath: workLog(for: run), contents: nil)
        }
        guard let output = FileHandle(forWritingAtPath: workLog(for: run)) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: workLog(for: run)])
        }
        output.seekToEndOfFile()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.wrapperScript, "sh"] + Self.workArguments(
            run: run, mode: mode, promptFile: promptFile(for: run), logFile: agentLog(for: run)
        )
        process.currentDirectoryURL = URL(fileURLWithPath: repoPath)
        process.environment = environment.merging(
            ["SUPERLINEAR_STATUS_FILE": statusFile(for: run)], uniquingKeysWith: { $1 }
        )
        // A file rather than a pipe: a pipe would break when the daemon exits
        // and take the agent down with it.
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice

        let statusFile = statusFile(for: run)
        process.terminationHandler = { _ in
            try? output.close()
            onExit(Self.readStatus(atPath: statusFile))
        }
        try process.run()

        var launched = run
        launched.pid = process.processIdentifier
        launched.processStartedAt = Self.startTime(of: process.processIdentifier)
        return (launched, process)
    }

    /// The prompt that starts the run's session.
    static func prompt(for run: AgentRun) -> String {
        if let review = run.review { return reviewPrompt(for: review, gitHubIssue: run.gitHubIssue) }
        if let conflict = run.conflict { return conflictPrompt(for: conflict, gitHubIssue: run.gitHubIssue) }
        return run.gitHubIssue.map { gitHubIssuePrompt(number: $0) } ?? autonomousPrompt
    }

    // MARK: Recovery

    static func recovery(status: Int32?, running: Bool, launched: Bool, resumes: Int) -> Recovery {
        if let status { return .finished(status) }
        if running { return .adopt }
        if !launched { return .waiting }
        return resumes >= maxResumes ? .abandon : .requeue
    }

    func recovery(for run: AgentRun) -> Recovery {
        Self.recovery(
            status: Self.readStatus(atPath: statusFile(for: run)),
            running: Self.isRunning(run),
            launched: !run.isQueued,
            resumes: run.resumes
        )
    }

    /// Resumes the run's Claude session when Claude saved one, which it has
    /// after an interruption; otherwise starts the session under the run's ID.
    func launchMode(for run: AgentRun) -> LaunchMode {
        claudeSessionExists(run.sessionId) ? .resume : .start
    }

    /// The waiting run to launch next: one the Claude usage limit stopped,
    /// then the new issue a standup moved furthest up, by `rank`, then the
    /// run queued longest ago.
    static func nextQueued<Key>(
        _ runs: [(Key, AgentRun)], rank: (Key, AgentRun) -> Int? = { _, _ in nil }
    ) -> (Key, AgentRun)? {
        runs.filter { $0.1.isQueued }.min { a, b in
            let (limitedA, limitedB) = (a.1.usageLimited == true, b.1.usageLimited == true)
            if limitedA != limitedB { return limitedA }
            let rankA = (a.1.isFresh ? rank(a.0, a.1) : nil) ?? .max
            let rankB = (b.1.isFresh ? rank(b.0, b.1) : nil) ?? .max
            if rankA != rankB { return rankA < rankB }
            let (dateA, dateB) = (a.1.queuedAt ?? .distantPast, b.1.queuedAt ?? .distantPast)
            return dateA == dateB ? a.1.identifier < b.1.identifier : dateA < dateB
        }
    }

    /// Calls `onExit` with the status of a running agent this daemon did not
    /// launch, once it ends. Keep the returned source alive until then.
    func watch(_ run: AgentRun, onExit: @escaping @Sendable (Int32?) -> Void) -> DispatchSourceProcess? {
        guard let pid = run.pid else { return nil }
        let statusFile = statusFile(for: run)
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler {
            source.cancel()
            onExit(Self.readStatus(atPath: statusFile))
        }
        source.resume()
        // It may have exited before the source was watching.
        if !Self.isRunning(run) {
            source.cancel()
            onExit(Self.readStatus(atPath: statusFile))
            return nil
        }
        return source
    }

    /// The Claude usage limit message the run's session ended with, if it
    /// did: the end of its log, written by `work`, which starts the log
    /// afresh for a new session and appends to it for a resumed one.
    func usageLimitHit(for run: AgentRun, now: Date) -> ClaudeUsageLimit.Hit? {
        guard let handle = FileHandle(forReadingAtPath: agentLog(for: run)) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > Self.logTailSize ? size - Self.logTailSize : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return ClaudeUsageLimit.hit(in: String(decoding: data, as: UTF8.self), now: now, timeZone: .current)
    }

    /// How much of the end of an agent's log is searched for the usage limit.
    static let logTailSize: UInt64 = 8 * 1024

    /// Removes the files a finished run leaves behind.
    func cleanUp(_ run: AgentRun) {
        try? FileManager.default.removeItem(atPath: statusFile(for: run))
        try? FileManager.default.removeItem(atPath: promptFile(for: run))
    }

    static func readStatus(atPath path: String) -> Int32? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether the run's process is alive and is the one that was launched,
    /// rather than an unrelated process that reused its pid.
    static func isRunning(_ run: AgentRun) -> Bool {
        isRunning(pid: run.pid, startedAt: run.processStartedAt)
    }

    static func isRunning(pid: Int32?, startedAt recorded: Date?) -> Bool {
        guard let pid, let recorded, let actual = startTime(of: pid) else { return false }
        return abs(actual.timeIntervalSince(recorded)) < 1
    }

    static func startTime(of pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(
            timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                + TimeInterval(info.pbi_start_tvusec) / 1_000_000
        )
    }

    /// Whether Claude saved a transcript for the session, without which it
    /// cannot be resumed. Claude keeps one file per session, named by its ID,
    /// under a directory per working directory.
    func claudeSessionExists(_ sessionId: String) -> Bool {
        let configDirectory = environment["CLAUDE_CONFIG_DIR"] ?? "\(home)/.claude"
        let projects = "\(configDirectory)/projects"
        let fm = FileManager.default
        guard let directories = try? fm.contentsOfDirectory(atPath: projects) else { return false }
        return directories.contains { fm.fileExists(atPath: "\(projects)/\($0)/\(sessionId).jsonl") }
    }
}
