import Foundation

/// Runs roadmap sessions and reads what they leave, as `PlanningRunner`
/// does for planning jobs. The session is read only, like the planning
/// job's, and reads every workspace: each repository is added to it, and it
/// runs `git`, `gh` and `linctl` for a workspace through small scripts that
/// run them in its repository, with its Linear key from the environment. So
/// no key is in the prompt or the allowed commands, and the allowed commands
/// read and nothing more.
struct RoadmapRunner: Sendable {
    let home: String
    let environment: [String: String]

    init(home: String = Paths.home, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = home
        self.environment = environment
    }

    var runsDirectory: String { "\(home)/.local/share/superlinear/runs" }
    var logsDirectory: String { "\(home)/.local/share/superlinear/logs" }
    /// The scripts through which the session reads each workspace: its
    /// repository with `git` and `gh`, and its Linear with `linctl`.
    func toolsDirectory(_ sessionId: ClaudeSession.ID) -> String { "\(runsDirectory)/roadmap-\(sessionId).tools" }
    /// Claude's output for roadmap sessions, appended across runs.
    var log: String { "\(logsDirectory)/roadmap.log" }

    func statusFile(_ sessionId: ClaudeSession.ID) -> String { "\(runsDirectory)/roadmap-\(sessionId).status" }
    func promptFile(_ sessionId: ClaudeSession.ID) -> String { "\(runsDirectory)/roadmap-\(sessionId).prompt" }
    func resumePromptFile(_ sessionId: ClaudeSession.ID) -> String { "\(runsDirectory)/roadmap-\(sessionId).resume.prompt" }
    func contextFile(_ sessionId: ClaudeSession.ID) -> String { "\(runsDirectory)/roadmap-\(sessionId).context.json" }
    func outputFile(_ sessionId: ClaudeSession.ID) -> String { "\(runsDirectory)/roadmap-\(sessionId).roadmap.json" }

    /// The variable that holds the Linear key of the workspace at `index`.
    static func keyVariable(_ index: Int) -> String { "SUPERLINEAR_LINEAR_KEY_\(index)" }

    /// The read-only commands of each tool that the session may run.
    static let tools: [(name: String, commands: [String])] = [
        ("git", ["log", "show", "diff"]),
        ("gh", ["pr view", "pr list"]),
        ("linctl", ["issue get", "issue list", "issue search"]),
    ]

    /// The script that runs `tool` for the workspace at `index`.
    func script(_ tool: String, _ index: Int, sessionId: ClaudeSession.ID) -> String { "\(toolsDirectory(sessionId))/\(index)/\(tool)" }

    /// The text of the script that runs `tool` for the workspace at `index`,
    /// whose repository is at `repository`. It holds the name of the key's
    /// variable, never the key.
    static func scriptText(_ tool: String, _ index: Int, repository: String) -> String {
        let quoted = "'" + repository.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let line = switch tool {
        case "git": "exec git -C \(quoted) \"$@\""
        case "gh": "cd \(quoted) && exec gh \"$@\""
        default: "LINCTL_API_KEY=\"$\(keyVariable(index))\" exec linctl \"$@\""
        }
        return "#!/bin/sh\n\(line)\n"
    }

    /// The commands the prompt names for the workspace at `index`.
    func commands(_ index: Int, sessionId: ClaudeSession.ID) -> [String: String] {
        Dictionary(uniqueKeysWithValues: Self.tools.map { ($0.name, script($0.name, index, sessionId: sessionId)) })
    }

    /// The tools the session may use: reading the code, each workspace's
    /// history, pull requests and Linear issues through its scripts, and
    /// writing its file.
    func allowedTools(workspaces: Int, sessionId: ClaudeSession.ID) -> String {
        let scripts = (0..<workspaces).flatMap { index in
            Self.tools.flatMap { tool in tool.commands.map { "Bash(\(script(tool.name, index, sessionId: sessionId)) \($0):*)" } }
        }
        return (["Read", "Grep", "Glob", "Write"] + scripts).joined(separator: ",")
    }

    func claudeArguments(
        sessionId: ClaudeSession.ID, mode: LaunchMode, model: PlanningModel, repositories: [String]
    ) -> [String] {
        ["claude", "-p", mode == .resume ? "--resume" : "--session-id", sessionId.rawValue] + model.arguments
            + ["--allowedTools", allowedTools(workspaces: repositories.count, sessionId: sessionId), "--add-dir", runsDirectory]
            + repositories.flatMap { ["--add-dir", $0] }
    }

    /// Writes the session's context, prompt and scripts, ahead of its
    /// first launch.
    func prepare(_ context: RoadmapContext, sessionId: ClaudeSession.ID) throws {
        let fm = FileManager.default
        for (index, workspace) in context.workspaces.enumerated() {
            try fm.createDirectory(atPath: "\(toolsDirectory(sessionId))/\(index)", withIntermediateDirectories: true)
            for tool in Self.tools {
                let path = script(tool.name, index, sessionId: sessionId)
                try Self.scriptText(tool.name, index, repository: workspace.worktreePath).write(toFile: path, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(context).write(to: URL(fileURLWithPath: contextFile(sessionId)), options: .atomic)
        let commands = Dictionary(uniqueKeysWithValues: context.workspaces.enumerated().map { ($1.name, self.commands($0, sessionId: sessionId)) })
        try RoadmapPrompt.render(context, outputPath: outputFile(sessionId), commands: commands)
            .write(toFile: promptFile(sessionId), atomically: true, encoding: .utf8)
    }

    /// The environment a session launches with: the caller's, without its
    /// own Linear key, with each workspace's key in its variable, in the
    /// order of `apiKeys`, and the status file.
    func launchEnvironment(_ sessionId: ClaudeSession.ID, apiKeys: [String]) -> [String: String] {
        var variables = ["SUPERLINEAR_STATUS_FILE": statusFile(sessionId)]
        for (index, key) in apiKeys.enumerated() { variables[Self.keyVariable(index)] = key }
        return LinearKey.withoutKey(environment).merging(variables, uniquingKeysWith: { $1 })
    }

    /// Starts the session and calls `onExit` with Claude's status — nil when
    /// it left none — once it ends.
    func launch(
        _ sessionId: ClaudeSession.ID, mode: LaunchMode, model: PlanningModel, context: RoadmapContext, apiKeys: [String],
        onExit: @escaping @Sendable (Int32?) -> Void
    ) throws -> Process {
        let fm = FileManager.default
        try fm.createDirectory(atPath: runsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: logsDirectory, withIntermediateDirectories: true)
        try? fm.removeItem(atPath: statusFile(sessionId))

        let prompt: String
        if mode == .resume {
            prompt = resumePromptFile(sessionId)
            try RoadmapPrompt.resume(outputPath: outputFile(sessionId)).write(toFile: prompt, atomically: true, encoding: .utf8)
        } else {
            prompt = promptFile(sessionId)
        }
        guard let input = FileHandle(forReadingAtPath: prompt) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: prompt])
        }
        if !fm.fileExists(atPath: log) { fm.createFile(atPath: log, contents: nil) }
        guard let output = FileHandle(forWritingAtPath: log) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: log])
        }
        output.seekToEndOfFile()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", AgentRunner.wrapperScript, "sh"]
            + claudeArguments(sessionId: sessionId, mode: mode, model: model, repositories: context.workspaces.map(\.worktreePath))
        process.currentDirectoryURL = URL(fileURLWithPath: runsDirectory)
        process.environment = launchEnvironment(sessionId, apiKeys: apiKeys)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        let statusFile = statusFile(sessionId)
        process.terminationHandler = { _ in
            try? output.close()
            try? input.close()
            onExit(AgentRunner.readStatus(atPath: statusFile))
        }
        try process.run()
        return process
    }

    /// What the session wrote.
    func output(_ sessionId: ClaudeSession.ID) throws -> RoadmapOutput {
        guard let data = FileManager.default.contents(atPath: outputFile(sessionId)) else {
            throw RoadmapError.noOutput(outputFile(sessionId))
        }
        return try RoadmapOutput.decoded(from: data)
    }

    func usage(_ sessionId: ClaudeSession.ID) -> AgentUsage? {
        PlanningRunner(home: home, environment: environment).usage(sessionId)
    }

    func usageLimitHit(now: Date) -> ClaudeUsageLimit.Hit? {
        AgentRunner.usageLimitHit(inLog: log, now: now)
    }

    func cleanUp(_ sessionId: ClaudeSession.ID) {
        let files = [statusFile(sessionId), promptFile(sessionId), resumePromptFile(sessionId), contextFile(sessionId), outputFile(sessionId)]
        for path in files + [toolsDirectory(sessionId)] {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

enum RoadmapError: Error, CustomStringConvertible {
    case noOutput(String)

    var description: String {
        switch self {
        case .noOutput(let path): "The session wrote no roadmap file at \(path)"
        }
    }
}

/// Builds a roadmap, the same for the daemon and `superlinear roadmap`.
struct RoadmapBuilder: Sendable {
    var runner = RoadmapRunner()

    enum Outcome: Sendable {
        case built(Roadmap)
        /// Another session is building this roadmap now.
        case busy(String)
        case failed(String)
    }

    /// Gathers the context of `workspaces`, runs the session on `model`, or
    /// on the fallback once Fable's limit stops it, and keeps the roadmap in
    /// the roadmap file. Returns the outcome and the Fable limit it met, if
    /// it met one.
    func build(
        workspaces: [WorkspaceConfig], state: State, model: PlanningModel, say: @Sendable (String) -> Void
    ) async -> (Outcome, fableLimit: ClaudeUsageLimit.Hit?) {
        let names = workspaces.map(\.name)
        let key = RoadmapRecord.key(names)
        if let running = RoadmapRecord.load().building[key], running.isRunning {
            return (.busy("A roadmap session is building it now (session \(running.sessionId))"), nil)
        }
        say("Gathering the issues, proposals and pull requests of \(names.joined(separator: ", "))")
        let context = await RoadmapGatherer.gather(workspaces: workspaces, state: state, now: Date())
        let sessionId = ClaudeSession.ID(rawValue: UUID().uuidString.lowercased())
        do {
            try runner.prepare(context, sessionId: sessionId)
        } catch {
            return (.failed("Could not write the session's files: \(error)"), nil)
        }
        defer { runner.cleanUp(sessionId) }
        let apiKeys = workspaces.map(\.apiKey)

        var model = model
        var hit: ClaudeUsageLimit.Hit?
        say("Claude is building the roadmap on \(model.rawValue); this takes a few minutes")
        say("  Log: \(runner.log)")
        var status: Int32?
        do {
            status = try await launch(sessionId, mode: .start, model: model, context: context, apiKeys: apiKeys, key: key)
            if model == .fable, let found = runner.usageLimitHit(now: Date()) {
                hit = found
                model = PlanningModel.fallback
                say("Fable's usage limit is reached; resuming the roadmap session on \(model.rawValue)")
                status = try await launch(sessionId, mode: .resume, model: model, context: context, apiKeys: apiKeys, key: key)
            }
        } catch {
            clearBuilding(key)
            return (.failed("Could not launch Claude: \(error)"), hit)
        }
        clearBuilding(key)
        guard status == 0 else {
            return (.failed("Claude exited \(status.map(String.init) ?? "without a status"); see \(runner.log)"), hit)
        }
        let output: RoadmapOutput
        do {
            output = try runner.output(sessionId)
        } catch {
            return (.failed("Could not read the roadmap: \(error)"), hit)
        }
        let roadmap = Roadmap.assemble(output, context: context, model: model, usage: runner.usage(sessionId))
        var record = RoadmapRecord.load()
        record.roadmaps[key] = roadmap
        do {
            try record.save()
        } catch {
            say("Could not save \(RoadmapRecord.fileURL().path): \(error)")
        }
        return (.built(roadmap), hit)
    }

    /// Launches the session, records it as building `key`, and waits for it.
    private func launch(
        _ sessionId: ClaudeSession.ID, mode: LaunchMode, model: PlanningModel, context: RoadmapContext, apiKeys: [String],
        key: String
    ) async throws -> Int32? {
        let (exits, exited) = AsyncStream<Int32?>.makeStream()
        let process = try runner.launch(sessionId, mode: mode, model: model, context: context, apiKeys: apiKeys) { status in
            exited.yield(status)
            exited.finish()
        }
        var record = RoadmapRecord.load()
        record.building[key] = RoadmapBuild(
            sessionId: sessionId, startedAt: Date(), pid: process.processIdentifier,
            processStartedAt: AgentRunner.startTime(of: process.processIdentifier))
        try? record.save()
        var status: Int32?
        for await exit in exits { status = exit }
        withExtendedLifetime(process) {}
        return status
    }

    private func clearBuilding(_ key: String) {
        var record = RoadmapRecord.load()
        guard record.building.removeValue(forKey: key) != nil else { return }
        try? record.save()
    }
}

/// `superlinear roadmap`: prints the last roadmap, or builds one.
enum RoadmapCommand {
    static func run(configPath: String?, workspaces names: [String]?, json: Bool, refresh: Bool) async -> Int32 {
        let config: Config
        do {
            config = try Config.load(from: configPath)
        } catch {
            print("[superlinear] Failed to load config: \(error)")
            return 1
        }
        var workspaces = config.workspaces
        if let names {
            let configured = config.workspaces.map(\.name)
            let unknown = names.filter { !configured.contains($0) }
            guard unknown.isEmpty else {
                print("[superlinear] No workspace named \(unknown.joined(separator: ", ")). Workspaces: \(configured.joined(separator: ", "))")
                return 1
            }
            workspaces = config.workspaces.filter { names.contains($0.name) }
        }
        guard !workspaces.isEmpty else {
            print("[superlinear] No workspaces configured. Edit ~/.config/superlinear/config.json")
            return 1
        }

        let key = RoadmapRecord.key(workspaces.map(\.name))
        var roadmap = refresh ? nil : RoadmapRecord.load().roadmaps[key]
        if roadmap == nil {
            // Progress goes to standard error, so `--json` prints only JSON.
            let say: @Sendable (String) -> Void = { FileHandle.standardError.write(Data("[superlinear] \($0)\n".utf8)) }
            let state = State.loadWithPlanning(from: State.stateFileURL(), planning: PlanningRecord.load())
            // The daemon owns the state file, so a Fable limit found here is
            // not kept: the next build finds it again.
            let model = PlanningModel.current(limit: state.fableLimit, now: Date())
            switch await RoadmapBuilder().build(workspaces: workspaces, state: state, model: model, say: say).0 {
            case .built(let built):
                roadmap = built
            case .busy(let reason), .failed(let reason):
                say(reason)
                roadmap = RoadmapRecord.load().roadmaps[key]
                guard roadmap != nil else { return 1 }
                say("Showing the last roadmap instead")
            }
        }
        guard let roadmap else { return 1 }

        if json {
            do {
                print(String(decoding: try roadmap.json(), as: UTF8.self))
            } catch {
                print("[superlinear] Could not encode the roadmap: \(error)")
                return 1
            }
            return 0
        }
        print(roadmap.rendered(now: Date(), links: isatty(STDOUT_FILENO) == 1, moved: moved(roadmap, workspaces: workspaces)))
        return 0
    }

    /// The workspaces whose default branch, as known locally, is not at the
    /// head the roadmap looked at.
    static func moved(_ roadmap: Roadmap, workspaces: [WorkspaceConfig]) -> [String] {
        workspaces.compactMap { workspace in
            guard let seen = roadmap.heads[workspace.name] else { return nil }
            let repoPath = NSString(string: workspace.repoPath).expandingTildeInPath
            guard let branch = PlanningGit.defaultBranch(repoPath: repoPath),
                  let head = Git.run(["rev-parse", "--verify", "--quiet", PlanningGit.ref(of: branch, repoPath: repoPath)], in: repoPath)
            else { return nil }
            return head == seen.rawValue ? nil : workspace.name
        }
    }
}
