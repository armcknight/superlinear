import Foundation

actor Daemon {
    private var state: State
    private let config: Config
    private let runner = AgentRunner()
    /// Agents this daemon launched, kept so their termination handlers fire.
    private var processes: [String: Process] = [:]
    /// Watches on agents an earlier daemon launched, keyed by issue ID.
    private var watchers: [String: DispatchSourceProcess] = [:]
    /// Set while recovery sorts the runs, which it must finish before any slot
    /// is counted as free.
    private var recovering = false
    /// Set when a launch fails, as when the disk is full. Launches wait until
    /// then, and the run stays queued, rather than every queued run failing in
    /// turn and leaving the queue.
    private var launchesPausedUntil: Date?
    private static let launchRetryDelay: TimeInterval = 60
    /// Failed launches after which a run is dropped, so one that can never
    /// launch, such as one whose repository is gone, does not cycle forever.
    static let maxLaunchFailures = 10
    /// The queue length last logged, so a retry each poll does not repeat it.
    private var reportedQueueLength: Int?
    /// Messages logged through firstReport.
    private var reported: Set<String> = []

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
            // Retries queued runs whose launch failed, once the pause is over.
            fillSlots()
            do {
                try await Task.sleep(for: .seconds(workspace.pollIntervalSeconds))
            } catch {
                break // Task cancelled
            }
        }
        log("Workspace loop stopped", workspace: workspace.name)
    }

    // MARK: - Agents

    /// Queues an agent for a new issue and starts it when a slot is free. The
    /// issue counts as processed from the moment it is queued, so no later poll
    /// queues it twice, and the poll does not wait for its agent.
    func enqueueAgent(for issue: LinearIssue, workspace: WorkspaceConfig) {
        let run = AgentRun(
            issueId: issue.id,
            identifier: issue.identifier,
            branchName: issue.branchName,
            sessionId: UUID().uuidString.lowercased(),
            queuedAt: Date()
        )
        state.markProcessed(issue.id, workspace: workspace.name)
        state.recordRun(run, workspace: workspace.name)
        log("Queued \(issue.identifier): \(issue.title)", workspace: workspace.name)
        save()
        fillSlots()
    }

    /// Picks up the runs a previous daemon left in the state file.
    private func recoverRuns() {
        recovering = true
        for (name, workspaceState) in state.workspaces {
            for run in workspaceState.inFlight.values {
                guard let workspace = workspace(named: name) else {
                    log("Dropping \(run.identifier): workspace is no longer configured", workspace: name)
                    state.removeRun(issueId: run.issueId, workspace: name)
                    continue
                }
                recover(run, workspace: workspace)
            }
        }
        recovering = false
        save()
        fillSlots()
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
        case .waiting:
            break
        case .requeue:
            log("\(run.identifier) was interrupted; queued to resume", workspace: workspace.name)
            var requeued = run
            requeued.pid = nil
            requeued.processStartedAt = nil
            requeued.resumes += 1
            state.recordRun(requeued, workspace: workspace.name)
        case .abandon:
            log(
                "Giving up on \(run.identifier) after \(run.resumes) resumes; see \(runner.agentLog(for: run))",
                workspace: workspace.name
            )
            finish(run, status: nil, workspace: workspace.name)
        }
    }

    /// Launches queued runs, oldest first, until the agent limit is reached.
    private func fillSlots() {
        guard !recovering else { return }
        if let until = launchesPausedUntil {
            guard Date() >= until else { return }
            launchesPausedUntil = nil
        }
        while processes.count + watchers.count < config.maxConcurrentAgents {
            let queued = state.workspaces.flatMap { name, workspaceState in
                workspaceState.inFlight.values.map { (name, $0) }
            }.filter { workspace(named: $0.0) != nil }
            guard let (name, run) = AgentRunner.nextQueued(queued),
                  let workspace = workspace(named: name)
            else { break }
            guard launch(run, workspace: workspace) else { break }
        }
        let waiting = state.workspaces.values.reduce(0) { $0 + $1.inFlight.values.filter(\.isQueued).count }
        if waiting != reportedQueueLength, waiting > 0 || reportedQueueLength != nil {
            print("[superlinear] \(processes.count + watchers.count) agent(s) running, \(waiting) queued")
        }
        reportedQueueLength = waiting
    }

    /// Launches a queued run. Returns false when the launch failed; the run
    /// then stays queued and launches pause for a while.
    @discardableResult
    private func launch(_ run: AgentRun, workspace: WorkspaceConfig) -> Bool {
        let repoPath = NSString(string: workspace.repoPath).expandingTildeInPath
        let mode = runner.launchMode(for: run)
        do {
            let (launched, process) = try runner.launch(run, mode: mode, repoPath: repoPath) { status in
                Task { await self.finish(run, status: status, workspace: workspace.name) }
            }
            processes[run.issueId] = process
            state.recordRun(launched, workspace: workspace.name)
            log(mode == .resume ? "Resuming \(run.identifier)" : "Starting \(run.identifier)", workspace: workspace.name)
            log("  Branch: \(run.branchName)", workspace: workspace.name)
            log("  Session: \(run.sessionId)", workspace: workspace.name)
            log("  Log: \(runner.agentLog(for: run))", workspace: workspace.name)
            save()
            return true
        } catch {
            launchesPausedUntil = Date().addingTimeInterval(Self.launchRetryDelay)
            var failed = run
            failed.launchFailures = (run.launchFailures ?? 0) + 1
            if failed.launchFailures! >= Self.maxLaunchFailures {
                log(
                    "Giving up on \(run.identifier) after \(Self.maxLaunchFailures) failed launches: "
                        + "\(error.localizedDescription). It will not be retried.",
                    workspace: workspace.name
                )
                state.removeRun(issueId: run.issueId, workspace: workspace.name)
            } else {
                log(
                    "Could not start the agent for \(run.identifier); requeued at the back, "
                        + "launches paused \(Int(Self.launchRetryDelay)) seconds: \(error.localizedDescription)",
                    workspace: workspace.name
                )
                // To the back, so one bad run does not hold up the rest.
                failed.queuedAt = Date()
                state.recordRun(failed, workspace: workspace.name)
            }
            save()
            return false
        }
    }

    private func workspace(named name: String) -> WorkspaceConfig? {
        config.workspaces.first { $0.name == name }
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
        // Even an agent that failed may have opened a pull request first.
        state.awaitMerge(PendingMerge(run), workspace: workspace)
        runner.cleanUp(run)
        save()
        fillSlots()
    }

    // MARK: - State accessors (called from WorkspaceProcessor on actor context)

    func lastPollTimestamp(workspace: String) -> Date {
        state.lastPollTimestamp(workspace: workspace)
    }

    func filterUnprocessed(_ issues: [LinearIssue], workspace: String) -> [LinearIssue] {
        issues.filter { !state.isProcessed($0.id, workspace: workspace) }
    }

    func pendingMerges(workspace: String) -> [PendingMerge] {
        state.pendingMerges(workspace: workspace)
    }

    /// Runs whose agents are running now, to check for pull requests opened
    /// before the agent ends.
    func launchedRuns(workspace: String) -> [AgentRun] {
        state.runs(workspace: workspace).filter { !$0.isQueued }
    }

    /// Issues the daemon follows itself, through a run or a merge watch.
    func trackedIssueIds(workspace: String) -> Set<String> {
        guard let workspaceState = state.workspaces[workspace] else { return [] }
        return Set(workspaceState.inFlight.keys).union(workspaceState.pendingMerges.keys)
    }

    func forgetLinkedPullRequests(issueId: String, workspace: String) {
        state.forgetLinkedPullRequests(issueId: issueId, workspace: workspace)
        save()
    }

    /// Whether `message` has not been reported before, so a problem that
    /// repeats every poll, such as a read-only API key, is logged once.
    func firstReport(_ message: String) -> Bool {
        reported.insert(message).inserted
    }

    func linkedPullRequests(issueId: String, workspace: String) -> Set<String> {
        state.linkedPullRequests(issueId: issueId, workspace: workspace)
    }

    func recordLinkedPullRequest(_ url: String, issueId: String, workspace: String) {
        state.recordLinkedPullRequest(url, issueId: issueId, workspace: workspace)
        save()
    }

    func stopAwaitingMerge(issueId: String, workspace: String) {
        state.stopAwaitingMerge(issueId: issueId, workspace: workspace)
        save()
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
