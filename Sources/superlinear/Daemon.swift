import Foundation

actor Daemon {
    private var state: State
    private let config: Config
    private let runner = AgentRunner()
    /// Agents this daemon launched, kept so their termination handlers fire.
    private var processes: [String: Process] = [:]
    /// Watches on agents an earlier daemon launched, keyed by issue ID.
    private var watchers: [String: DispatchSourceProcess] = [:]

    init(config: Config) {
        self.config = config
        self.state = State.load()
    }

    func run() async throws {
        print("[superlinear] Starting with \(config.workspaces.count) workspace(s)")

        recoverRuns()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for workspace in config.workspaces {
                group.addTask {
                    await self.runWorkspaceLoop(workspace)
                }
            }
            try await group.waitForAll()
        }
    }

    private func runWorkspaceLoop(_ workspace: WorkspaceConfig) async {
        let processor = WorkspaceProcessor(workspace: workspace, daemon: self)
        while !Task.isCancelled {
            do {
                try await processor.poll()
            } catch {
                log("Poll error: \(error)", workspace: workspace.name)
            }
            do {
                try await Task.sleep(for: .seconds(workspace.pollIntervalSeconds))
            } catch {
                break // Task cancelled
            }
        }
        log("Workspace loop stopped", workspace: workspace.name)
    }

    // MARK: - Agents

    /// Starts an agent for a new issue. The issue counts as processed from the
    /// moment its agent starts, so no later poll starts a second one, and the
    /// poll does not wait for it.
    func startAgent(for issue: LinearIssue, workspace: WorkspaceConfig) {
        let run = AgentRun(
            issueId: issue.id,
            identifier: issue.identifier,
            branchName: issue.branchName,
            sessionId: UUID().uuidString.lowercased()
        )
        state.markProcessed(issue.id, workspace: workspace.name)
        log("Processing issue \(issue.identifier): \(issue.title)", workspace: workspace.name)
        launch(run, mode: .start, workspace: workspace)
    }

    /// Picks up the runs a previous daemon left in the state file.
    private func recoverRuns() {
        for (name, workspaceState) in state.workspaces {
            for run in workspaceState.inFlight.values {
                guard let workspace = config.workspaces.first(where: { $0.name == name }) else {
                    log("Dropping \(run.identifier): workspace is no longer configured", workspace: name)
                    state.removeRun(issueId: run.issueId, workspace: name)
                    continue
                }
                recover(run, workspace: workspace)
            }
        }
        save()
    }

    private func recover(_ run: AgentRun, workspace: WorkspaceConfig) {
        switch runner.recovery(for: run) {
        case .finished(let status):
            log("\(run.identifier) finished while the daemon was stopped", workspace: workspace.name)
            finish(run, status: status, workspace: workspace.name)
        case .adopt:
            log("\(run.identifier) is still running (pid \(run.pid ?? 0)); waiting for it", workspace: workspace.name)
            if let source = runner.watch(run, onExit: { status in
                Task { await self.finish(run, status: status, workspace: workspace.name) }
            }) {
                watchers[run.issueId] = source
            }
        case .resume:
            log("Resuming \(run.identifier), interrupted", workspace: workspace.name)
            var resumed = run
            resumed.resumes += 1
            launch(resumed, mode: .resume, workspace: workspace)
        case .restart:
            log("Restarting \(run.identifier), interrupted before Claude saved a session", workspace: workspace.name)
            var restarted = run
            restarted.resumes += 1
            launch(restarted, mode: .start, workspace: workspace)
        case .abandon:
            log(
                "Giving up on \(run.identifier) after \(run.resumes) resumes; see \(runner.agentLog(for: run))",
                workspace: workspace.name
            )
            finish(run, status: nil, workspace: workspace.name)
        }
    }

    private func launch(_ run: AgentRun, mode: LaunchMode, workspace: WorkspaceConfig) {
        let repoPath = NSString(string: workspace.repoPath).expandingTildeInPath
        do {
            let (launched, process) = try runner.launch(run, mode: mode, repoPath: repoPath) { status in
                Task { await self.finish(run, status: status, workspace: workspace.name) }
            }
            processes[run.issueId] = process
            state.recordRun(launched, workspace: workspace.name)
            log("  Branch: \(run.branchName)", workspace: workspace.name)
            log("  Session: \(run.sessionId)", workspace: workspace.name)
            log("  Log: \(runner.agentLog(for: run))", workspace: workspace.name)
        } catch {
            log("Could not start the agent for \(run.identifier): \(error)", workspace: workspace.name)
            state.removeRun(issueId: run.issueId, workspace: workspace.name)
        }
        save()
    }

    private func finish(_ run: AgentRun, status: Int32?, workspace: String) {
        processes[run.issueId] = nil
        watchers[run.issueId] = nil
        // A run is finished once; a late duplicate notice finds nothing to do.
        guard state.workspaces[workspace]?.inFlight[run.issueId]?.sessionId == run.sessionId else { return }

        switch status {
        case 0?: log("Agent completed for \(run.identifier)", workspace: workspace)
        case let status?: log("Agent for \(run.identifier) exited \(status); see \(runner.workLog(for: run))", workspace: workspace)
        case nil: log("Agent for \(run.identifier) ended without a status", workspace: workspace)
        }
        state.removeRun(issueId: run.issueId, workspace: workspace)
        runner.cleanUp(run)
        save()
    }

    // MARK: - State accessors (called from WorkspaceProcessor on actor context)

    func lastPollTimestamp(workspace: String) -> Date {
        state.lastPollTimestamp(workspace: workspace)
    }

    func filterUnprocessed(_ issues: [LinearIssue], workspace: String) -> [LinearIssue] {
        issues.filter { !state.isProcessed($0.id, workspace: workspace) }
    }

    func updateLastPoll(_ date: Date, workspace: String) {
        state.updateLastPoll(date, workspace: workspace)
        save()
    }

    private func save() {
        do {
            try state.save()
        } catch {
            print("[superlinear] Could not save state: \(error)")
        }
    }

    private func log(_ message: String, workspace: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] [\(workspace)] \(message)")
    }
}
