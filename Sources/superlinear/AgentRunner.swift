import Darwin
import Foundation

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
"""

private let resumePrompt = """
You were interrupted partway through the task above. Work out where you stopped — check the \
worktree's git status and log, the Linear issue's state, and whether a pull request exists and \
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
    func workLog(for run: AgentRun) -> String { "\(logsDirectory)/\(run.identifier).work.log" }

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

        let prompt = mode == .resume ? resumePrompt : autonomousPrompt
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

    /// The waiting run to launch next: the one queued longest ago.
    static func nextQueued<Key>(_ runs: [(Key, AgentRun)]) -> (Key, AgentRun)? {
        runs.filter { $0.1.isQueued }.min { a, b in
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
        guard let pid = run.pid, let recorded = run.processStartedAt,
              let actual = startTime(of: pid)
        else { return false }
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
