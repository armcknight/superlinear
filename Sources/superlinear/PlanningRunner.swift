import Foundation

/// Runs planning jobs' Claude sessions and reads what they leave.
///
/// A session runs `claude -p` in the default-branch worktree under the same
/// `sh` wrapper as an agent, which writes Claude's exit status to a file, so
/// that, like an agent, it outlives a daemon restart and a later daemon can
/// tell how it ended. Beside the status, the runs directory keeps the job's
/// prompt, the context it was given, and the proposals file it writes.
struct PlanningRunner: Sendable {
    /// The tools the session may use: reading the code and its history, and
    /// writing the proposals file.
    static let allowedTools = "Read,Grep,Glob,Write,Bash(git log:*),Bash(git show:*),Bash(git diff:*)"

    let home: String
    /// The environment sessions launch with. `claude` is found through its PATH.
    let environment: [String: String]

    init(home: String = Paths.home, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = home
        self.environment = environment
    }

    var runsDirectory: String { "\(home)/.local/share/superlinear/runs" }
    var logsDirectory: String { "\(home)/.local/share/superlinear/logs" }

    func statusFile(_ sessionId: ClaudeSession.ID) -> String { "\(runsDirectory)/planning-\(sessionId).status" }
    func promptFile(_ sessionId: ClaudeSession.ID) -> String { "\(runsDirectory)/planning-\(sessionId).prompt" }
    func resumePromptFile(_ sessionId: ClaudeSession.ID) -> String { "\(runsDirectory)/planning-\(sessionId).resume.prompt" }
    func contextFile(_ sessionId: ClaudeSession.ID) -> String { "\(runsDirectory)/planning-\(sessionId).context.json" }
    func outputFile(_ sessionId: ClaudeSession.ID) -> String { "\(runsDirectory)/planning-\(sessionId).proposals.json" }
    /// Claude's output for a workspace's jobs, appended across runs.
    func log(workspace: String) -> String { "\(logsDirectory)/planning-\(Transcripts.encoded(workspace)).log" }

    static func claudeArguments(sessionId: ClaudeSession.ID, mode: LaunchMode, runsDirectory: String) -> [String] {
        [
            "claude", "-p",
            mode == .resume ? "--resume" : "--session-id", sessionId.rawValue,
            "--allowedTools", allowedTools,
            "--add-dir", runsDirectory,
        ]
    }

    /// Writes the job's context and prompt, ahead of its first launch.
    func prepare(_ context: PlanningContext, sessionId: ClaudeSession.ID) throws {
        try FileManager.default.createDirectory(atPath: runsDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(context).write(to: URL(fileURLWithPath: contextFile(sessionId)), options: .atomic)
        try PlanningPrompt.render(context, outputPath: outputFile(sessionId))
            .write(toFile: promptFile(sessionId), atomically: true, encoding: .utf8)
    }

    /// Starts the session for `run` and calls `onExit` with Claude's status —
    /// nil when it left none — once it ends. Returns the run with the
    /// launched process recorded.
    func launch(
        _ run: PlanningRun, mode: LaunchMode, workspace: String, onExit: @escaping @Sendable (Int32?) -> Void
    ) throws -> (PlanningRun, Process) {
        let fm = FileManager.default
        try fm.createDirectory(atPath: runsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: logsDirectory, withIntermediateDirectories: true)
        try? fm.removeItem(atPath: statusFile(run.sessionId))

        let prompt: String
        if mode == .resume {
            prompt = resumePromptFile(run.sessionId)
            try PlanningPrompt.resume(outputPath: outputFile(run.sessionId)).write(toFile: prompt, atomically: true, encoding: .utf8)
        } else {
            prompt = promptFile(run.sessionId)
        }
        guard let input = FileHandle(forReadingAtPath: prompt) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: prompt])
        }
        let logPath = log(workspace: workspace)
        if !fm.fileExists(atPath: logPath) { fm.createFile(atPath: logPath, contents: nil) }
        guard let output = FileHandle(forWritingAtPath: logPath) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: logPath])
        }
        output.seekToEndOfFile()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", AgentRunner.wrapperScript, "sh"]
            + Self.claudeArguments(sessionId: run.sessionId, mode: mode, runsDirectory: runsDirectory)
        process.currentDirectoryURL = URL(fileURLWithPath: run.worktreePath)
        process.environment = environment.merging(
            ["SUPERLINEAR_STATUS_FILE": statusFile(run.sessionId)], uniquingKeysWith: { $1 }
        )
        // Files rather than pipes, which would break when the daemon exits.
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        let statusFile = statusFile(run.sessionId)
        process.terminationHandler = { _ in
            try? output.close()
            try? input.close()
            onExit(AgentRunner.readStatus(atPath: statusFile))
        }
        try process.run()

        var launched = run
        launched.pid = process.processIdentifier
        launched.processStartedAt = AgentRunner.startTime(of: process.processIdentifier)
        return (launched, process)
    }

    /// What a restarted daemon does with a job it finds in the state file.
    /// `waiting` does not arise, as a job is recorded once it launches.
    func recovery(for run: PlanningRun) -> Recovery {
        AgentRunner.recovery(
            status: AgentRunner.readStatus(atPath: statusFile(run.sessionId)),
            running: AgentRunner.isRunning(pid: run.pid, startedAt: run.processStartedAt),
            launched: true,
            resumes: run.resumes
        )
    }

    func launchMode(for run: PlanningRun) -> LaunchMode {
        AgentRunner(home: home, environment: environment).claudeSessionExists(run.sessionId.rawValue) ? .resume : .start
    }

    /// Calls `onExit` with the status of a running session this daemon did
    /// not launch, once it ends. Keep the returned source alive until then.
    func watch(_ run: PlanningRun, onExit: @escaping @Sendable (Int32?) -> Void) -> DispatchSourceProcess? {
        guard let pid = run.pid else { return nil }
        let statusFile = statusFile(run.sessionId)
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler {
            source.cancel()
            onExit(AgentRunner.readStatus(atPath: statusFile))
        }
        source.resume()
        if !AgentRunner.isRunning(pid: run.pid, startedAt: run.processStartedAt) {
            source.cancel()
            onExit(AgentRunner.readStatus(atPath: statusFile))
            return nil
        }
        return source
    }

    func context(_ sessionId: ClaudeSession.ID) throws -> PlanningContext {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PlanningContext.self, from: Data(contentsOf: URL(fileURLWithPath: contextFile(sessionId))))
    }

    /// The proposals the session wrote, checked against its context.
    func ingest(_ sessionId: ClaudeSession.ID) throws -> (PlanningIngest, PlanningContext) {
        let context = try context(sessionId)
        guard let data = FileManager.default.contents(atPath: outputFile(sessionId)) else {
            throw PlanningError.noOutput(outputFile(sessionId))
        }
        return (PlanningIngest(try PlanningOutput.decoded(from: data), context: context, sessionId: sessionId), context)
    }

    /// What the session used, from its transcripts, or nil when none was found.
    func usage(_ sessionId: ClaudeSession.ID) -> AgentUsage? {
        let configDirectory = environment["CLAUDE_CONFIG_DIR"] ?? "\(home)/.claude"
        let projects = "\(configDirectory)/projects"
        let fm = FileManager.default
        var transcripts: [(data: Data, isSubagent: Bool)] = []
        for directory in (try? fm.contentsOfDirectory(atPath: projects)) ?? [] {
            let main = "\(projects)/\(directory)/\(sessionId).jsonl"
            guard let data = fm.contents(atPath: main) else { continue }
            transcripts.append((data, false))
            // Subagents' transcripts, under a directory named after the session.
            let subagents = "\(projects)/\(directory)/\(sessionId)"
            for case let path as String in fm.enumerator(atPath: subagents) ?? NSEnumerator() where path.hasSuffix(".jsonl") {
                if let data = fm.contents(atPath: "\(subagents)/\(path)") { transcripts.append((data, true)) }
            }
        }
        return transcripts.isEmpty ? nil : AgentUsage.of(transcripts)
    }

    /// Removes the files a finished job leaves behind.
    func cleanUp(_ sessionId: ClaudeSession.ID) {
        for path in [statusFile(sessionId), promptFile(sessionId), resumePromptFile(sessionId), contextFile(sessionId), outputFile(sessionId)] {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

/// Starting and finishing a planning job, the same for the daemon and
/// `superlinear plan`, which differ in where they keep what it did.
struct PlanningJob: Sendable {
    let workspace: WorkspaceConfig
    var runner = PlanningRunner()

    /// Gathers the context of the job that follows the workspace's jobs in
    /// `history`, and writes its files, ready to launch.
    func prepare(
        history: [PlanningRunRecord], trigger: PlanningTrigger, linear: any PlanningReading, now: Date
    ) async throws -> PlanningRun {
        let context = try await PlanningGatherer(workspace: workspace, linear: linear)
            .gather(history: history, trigger: trigger, now: now)
        let run = PlanningRun(
            sessionId: ClaudeSession.ID(rawValue: UUID().uuidString.lowercased()), startedAt: now, worktreePath: context.worktreePath)
        try runner.prepare(context, sessionId: run.sessionId)
        return run
    }

    /// What a job that ended with `status` proposes, and its record, with
    /// the counts to fill in once the proposals are screened.
    func finish(_ run: PlanningRun, status: Int32?, now: Date) -> (PlanningRunRecord, PlanningIngest) {
        var record = PlanningRunRecord(
            sessionId: run.sessionId, startedAt: run.startedAt, endedAt: now, usage: runner.usage(run.sessionId))
        record.head = try? runner.context(run.sessionId).head
        // TODO: SPL-26. A session the usage limit stops ends here as a
        // failure; it is to be paused and resumed as agents are.
        guard status == 0 else {
            record.error = status.map { "Claude exited \($0); see \(runner.log(workspace: workspace.name))" }
                ?? "Claude ended without a status; see \(runner.log(workspace: workspace.name))"
            return (record, PlanningIngest())
        }
        do {
            let (ingest, _) = try runner.ingest(run.sessionId)
            record.skipped = ingest.refused.count
            return (record, ingest)
        } catch {
            record.error = "Could not read the proposals: \(error)"
            return (record, PlanningIngest())
        }
    }
}
