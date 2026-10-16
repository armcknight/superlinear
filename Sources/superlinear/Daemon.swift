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
    /// The GitHub login whose reviews agents address, once looked up.
    private var viewerLogin: String?
    /// Until when a GitHub rate limit is used up. Polls skip their GitHub
    /// work until then.
    private var gitHubPausedUntil: Date?
    /// What standups decided, read again at each poll.
    private var standups: StandupRecord
    /// What `superlinear plan` did, read again at each poll.
    private var planning: PlanningRecord
    private let planningRunner = PlanningRunner()
    /// Planning jobs this daemon launched, by workspace, kept so their
    /// termination handlers fire.
    private var planningProcesses: [String: Process] = [:]
    /// Watches on planning jobs an earlier daemon launched, by workspace.
    private var planningWatchers: [String: DispatchSourceProcess] = [:]
    /// Workspaces whose planning job is being gathered or its proposals
    /// stored, so that no second job starts meanwhile.
    private var planningBusy: Set<String> = []

    init(config: Config) {
        self.config = config
        self.state = State.load()
        self.standups = StandupRecord.load()
        self.planning = PlanningRecord.load()
    }

    func run() async throws {
        print("[superlinear] Starting with \(config.workspaces.count) workspace(s)")

        recoverRuns()
        sweepWorktrees()

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
            var failure: String?
            do {
                try await processor.poll()
            } catch {
                log("Poll error: \(error)", workspace: workspace.name)
                failure = "\(error)"
            }
            let ended = Date()
            state.recordPoll(
                PollRecord(
                    endedAt: ended, nextAt: ended.addingTimeInterval(TimeInterval(workspace.pollIntervalSeconds)),
                    error: failure
                ),
                workspace: workspace.name
            )
            save()
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
    /// queues it twice, and the poll does not wait for its agent. Issues queued
    /// at once start in the order of their `queuedAt`.
    func enqueueAgent(for issue: LinearIssue, workspace: WorkspaceConfig, queuedAt: Date = Date()) {
        let run = AgentRun(
            issueId: issue.id.rawValue,
            identifier: issue.identifier,
            branchName: issue.branchName,
            sessionId: UUID().uuidString.lowercased(),
            queuedAt: queuedAt
        )
        state.markProcessed(issue.id.rawValue, workspace: workspace.name)
        state.recordRun(run, workspace: workspace.name)
        log("Queued \(issue.identifier): \(issue.title)", workspace: workspace.name)
        save()
        fillSlots()
    }

    /// Queues an agent to address new reviews on the pull request of an issue
    /// awaiting its merge. It works in the issue's existing worktree, under a
    /// new Claude session, and the issue awaits its merge again once it ends.
    func enqueueReview(of pending: PendingMerge, pullRequest: PullRequest, workspace: WorkspaceConfig) {
        // The watch may have ended while the reviews were being read.
        guard state.workspaces[workspace.name]?.pendingMerges[pending.issueId] != nil else { return }
        let run = AgentRun(
            issueId: pending.issueId,
            identifier: pending.identifier,
            branchName: pending.branchName,
            sessionId: UUID().uuidString.lowercased(),
            queuedAt: Date(),
            review: ReviewRequest(number: pullRequest.number, url: pullRequest.url)
        )
        state.startReview(run, workspace: workspace.name)
        log("Queued \(pending.identifier) to address the review on \(pullRequest.url)", workspace: workspace.name)
        save()
        fillSlots()
    }

    /// Queues an agent to merge the base branch into the branch of an issue
    /// awaiting its merge whose pull request conflicts with it. Like a review
    /// run, it works in the issue's existing worktree, under a new Claude
    /// session, and the issue awaits its merge again once it ends.
    func enqueueConflictResolution(
        of pending: PendingMerge, pullRequest: PullRequest, baseBranch: String,
        attempt: ConflictAttempt, workspace: WorkspaceConfig
    ) {
        // The watch may have ended, or have had its review baseline set,
        // since the poll read it.
        guard let current = state.workspaces[workspace.name]?.pendingMerges[pending.issueId] else { return }
        let run = AgentRun(
            issueId: pending.issueId,
            identifier: pending.identifier,
            branchName: pending.branchName,
            sessionId: UUID().uuidString.lowercased(),
            queuedAt: Date(),
            conflict: ConflictRequest(
                number: pullRequest.number, url: pullRequest.url, baseBranch: baseBranch,
                attempt: attempt, reviewsHandledThrough: current.reviewsHandledThrough
            )
        )
        state.startReview(run, workspace: workspace.name)
        log(
            "Queued \(pending.identifier) to resolve the conflicts of \(pullRequest.url) with \(baseBranch)",
            workspace: workspace.name
        )
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
            if let run = workspaceState.planningRun {
                guard let workspace = workspace(named: name) else {
                    log("Dropping the planning job: workspace is no longer configured", workspace: name)
                    state.workspaces[name]?.planningRun = nil
                    continue
                }
                recoverPlanning(run, workspace: workspace)
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
            }.filter { name, run in
                // A standup's hold keeps an agent from starting on a new issue,
                // but not from going on with one it started.
                workspace(named: name) != nil && !(run.isFresh && standups[name].held[LinearIssue.ID(rawValue: run.issueId)] != nil)
            }
            guard let (name, run) = AgentRunner.nextQueued(queued, rank: { self.standups[$0].rank(of: LinearIssue.ID(rawValue: $1.issueId)) }),
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
            var run = run
            run.launchedAt = run.launchedAt ?? Date()
            let (launched, process) = try runner.launch(run, mode: mode, repoPath: repoPath) { [run] status in
                Task { await self.finish(run, status: status, workspace: workspace.name) }
            }
            processes[run.issueId] = process
            state.recordRun(launched, workspace: workspace.name)
            log(mode == .resume ? "Resuming \(run.identifier)" : "Starting \(run.identifier)", workspace: workspace.name)
            if run.review == nil, run.conflict == nil, mode == .start, run.resumes == 0 {
                state.recordActivity(
                    ActivityEvent(time: Date(), kind: .agentStarted, identifier: run.identifier), workspace: workspace.name)
                if workspace.selection == .ready { markStarted(run, workspace: workspace) }
            }
            if let review = run.review {
                log("  Addressing the review on \(review.url)", workspace: workspace.name)
            }
            if let conflict = run.conflict {
                log("  Resolving the conflicts of \(conflict.url) with \(conflict.baseBranch)", workspace: workspace.name)
            }
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
                state.recordActivity(
                    ActivityEvent(time: Date(), kind: .agentStopped, identifier: run.identifier,
                                  detail: "\(Self.maxLaunchFailures) failed launches"),
                    workspace: workspace.name
                )
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

    /// Moves the issue of a run just launched to its team's first started
    /// state, so it leaves the ready states. The agent does not wait for it.
    private func markStarted(_ run: AgentRun, workspace: WorkspaceConfig) {
        let client = LinearClient(apiKey: workspace.apiKey)
        Task.detached {
            do {
                if try await client.startIssue(id: run.issueId) {
                    await self.log("  Moved \(run.identifier) to started in Linear", workspace: workspace.name)
                }
            } catch {
                await self.log("  Could not move \(run.identifier) to started in Linear: \(error)", workspace: workspace.name)
            }
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
        state.recordActivity(.finished(run, status: status), workspace: workspace)
        // Even an agent that failed may have opened a pull request first.
        state.awaitMerge(PendingMerge(run), workspace: workspace)
        runner.cleanUp(run)
        save()
        fillSlots()
        cleanWorktree(of: run, workspace: workspace)
    }

    /// Frees the build output of an agent that has ended, as it goes.
    private func cleanWorktree(of run: AgentRun, workspace name: String) {
        guard let workspace = workspace(named: name) else { return }
        let repoPath = NSString(string: workspace.repoPath).expandingTildeInPath
        Task.detached {
            do {
                if let line = try await WorktreeCleaner().cleanAfterAgent(branch: run.branchName, repoPath: repoPath),
                   line.hasPrefix("Freed") {
                    await self.log(line, workspace: name)
                }
            } catch {
                await self.log("Could not clean the worktree for \(run.identifier): \(error)", workspace: name)
            }
        }
    }

    /// The startup sweep: cleans every worktree whose agent is not running and
    /// whose build output has sat idle, and DerivedData of removed worktrees.
    /// Runs in the background, so polling starts at once.
    private func sweepWorktrees() {
        for workspace in config.workspaces {
            let repoPath = NSString(string: workspace.repoPath).expandingTildeInPath
            let running = Set(state.runs(workspace: workspace.name).filter { !$0.isQueued }.map(\.branchName))
            Task.detached {
                let (freed, errors) = await WorktreeCleaner().sweep(repoPath: repoPath, running: running)
                for line in freed + errors {
                    await self.log(line, workspace: workspace.name)
                }
            }
        }
    }

    // MARK: - State accessors (called from WorkspaceProcessor on actor context)

    func lastPollTimestamp(workspace: String) -> Date {
        state.lastPollTimestamp(workspace: workspace)
    }

    /// Issues the daemon has queued, run or watched, which no poll starts again.
    func handledIssueIds(workspace: String) -> Set<LinearIssue.ID> {
        state.handledIssueIds(workspace: workspace)
    }

    /// Issues waiting on blockers, a human or a standup's hold, which each
    /// poll checks again.
    func waitingIssueIds(workspace: String) -> Set<LinearIssue.ID> {
        (state.workspaces[workspace]?.waitingIssueIds ?? []).union(standups[workspace].held.keys)
    }

    /// Records the issues the latest poll found waiting, logging those that
    /// were not waiting, or not for the same reason, before.
    func recordWaiting(_ plan: IssueSelectionPlan, workspace: String) {
        let before = state.workspaces[workspace] ?? WorkspaceState()
        for (id, issue) in plan.needsHuman.sorted(by: { $0.value.identifier < $1.value.identifier })
        where before.needsHuman[id] == nil {
            log("\(issue.identifier) needs a human (\(issue.labels.joined(separator: ", "))); "
                + "no agent starts on it", workspace: workspace)
        }
        for (id, issue) in plan.blocked.sorted(by: { $0.value.identifier < $1.value.identifier })
        where before.blocked[id]?.blockers != issue.blockers {
            log("\(issue.identifier) waits for \(issue.blockers.joined(separator: ", "))", workspace: workspace)
        }
        state.recordWaiting(blocked: plan.blocked, needsHuman: plan.needsHuman, workspace: workspace)
        save()
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

    /// The time through which the issue's reviews count as addressed. A watch
    /// from before reviews were followed has none; it takes the date of the
    /// pull request's head commit, as no agent can have addressed a review
    /// submitted after its last push, or else the present.
    func reviewsHandledThrough(_ pending: PendingMerge, lastCommit: Date?, workspace: String) -> Date {
        if let date = pending.reviewsHandledThrough { return date }
        let date = lastCommit ?? Date()
        state.workspaces[workspace]?.pendingMerges[pending.issueId]?.reviewsHandledThrough = date
        save()
        return date
    }

    /// The GitHub login `gh` is signed in as, looked up once.
    func viewerLogin(repoPath: String) async throws -> String {
        if let viewerLogin { return viewerLogin }
        let login = try await PullRequestChecker().viewerLogin(repoPath: repoPath)
        viewerLogin = login
        return login
    }

    func recordActivity(_ event: ActivityEvent, workspace: String) {
        state.recordActivity(event, workspace: workspace)
        save()
    }

    // MARK: - Standups

    /// Reads the planning and standup files again, and takes in the
    /// proposals `superlinear plan` stored, then what standups decided about
    /// the workspace's proposals.
    func takeInStandups(workspace: String) {
        standups = StandupRecord.load()
        planning = PlanningRecord.load()
        let before = state.proposals(workspace: workspace)
        if state.takeIn(planning[workspace], workspace: workspace) {
            log("Took in proposals from `superlinear plan`", workspace: workspace)
        }
        state.takeIn(standups[workspace], workspace: workspace)
        if state.proposals(workspace: workspace) != before { save() }
    }

    /// The workspace's latest standup decisions.
    func standup(workspace: String) -> WorkspaceStandup {
        standups[workspace]
    }

    func forgetLinkedPullRequests(issueId: String, workspace: String) {
        state.forgetLinkedPullRequests(issueId: issueId, workspace: workspace)
        save()
    }

    /// Whether polls may call GitHub now. Logs when a pause ends.
    func gitHubAvailable(now: Date = Date()) -> Bool {
        guard let until = gitHubPausedUntil else { return true }
        guard now >= until else { return false }
        gitHubPausedUntil = nil
        print("[\(ISO8601DateFormatter().string(from: now))] GitHub's rate limit has reset; checking pull requests again")
        return true
    }

    /// Skips GitHub work until `until`, logging once per pause.
    func pauseGitHub(until: Date) {
        if gitHubPausedUntil == nil {
            let formatter = ISO8601DateFormatter()
            print("[\(formatter.string(from: Date()))] GitHub's rate limit is used up until \(formatter.string(from: until)); "
                + "skipping pull request checks until then")
        }
        gitHubPausedUntil = max(gitHubPausedUntil ?? until, until)
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

    // MARK: - Proposals

    /// Stores a proposed change to Linear, unless the same change is pending
    /// or was rejected, or its kind is set to never. One whose kind is `auto`
    /// is applied at once. Returns the proposal as stored, or nil when none was.
    @discardableResult
    func propose(_ draft: ProposalDraft, workspace: WorkspaceConfig) async -> Proposal? {
        let engine = proposalEngine(workspace)
        let screening: ProposalEngine.Screening
        do {
            screening = try await engine.screen(draft, existing: state.proposals(workspace: workspace.name))
        } catch {
            log("Could not check a \(draft.payload.kind.rawValue) proposal for duplicates: \(error)", workspace: workspace.name)
            return nil
        }
        guard case .store(let proposal, let applyNow) = screening else {
            if case .skip(let reason) = screening {
                log("Not proposing \(draft.payload.kind.rawValue): \(reason)", workspace: workspace.name)
            }
            return nil
        }
        // Another proposal may have been stored while the screening waited on Linear.
        let sameness = proposal.sameness
        guard !state.proposals(workspace: workspace.name).contains(where: {
            $0.sameness == sameness && [.pending, .rejected].contains($0.status)
        }) else { return nil }
        state.recordProposal(proposal, workspace: workspace.name)
        save()
        log("Proposed \(proposal.kind.rawValue) \(proposal.id): \(proposal.reason)", workspace: workspace.name)
        return applyNow ? await applyProposal(proposal, workspace: workspace) : proposal
    }

    /// Applies a pending proposal and records what became of it.
    func applyProposal(_ proposal: Proposal, workspace: WorkspaceConfig) async -> Proposal {
        let result = await proposalEngine(workspace).apply(proposal)
        state.recordProposal(result, workspace: workspace.name)
        save()
        let outcome = switch result.status {
        case .applied: "Applied"
        case .rejected: "Rejected (\(result.rejectionReason ?? "no reason"))"
        default: "Left pending (\(result.lastError ?? result.reviewNote ?? "for review"))"
        }
        log("\(outcome) \(result.kind.rawValue) \(result.id)", workspace: workspace.name)
        return result
    }

    func expireProposals(workspace: WorkspaceConfig) {
        let expired = state.expireProposals(olderThanDays: workspace.proposalExpiryDays, workspace: workspace.name)
        guard !expired.isEmpty else { return }
        log("Expired \(expired.count) proposal(s) pending over \(workspace.proposalExpiryDays) days", workspace: workspace.name)
        save()
    }

    private func proposalEngine(_ workspace: WorkspaceConfig) -> ProposalEngine {
        ProposalEngine(
            workspace: workspace.name, autonomy: workspace.autonomy,
            linear: LinearClient(apiKey: workspace.apiKey), audit: AuditLog()
        )
    }

    // MARK: - Planning

    /// Starts the workspace's planning job when planning is on, none is
    /// running, and the last one, the daemon's or `superlinear plan`'s,
    /// started `PlanningSchedule.interval` or more ago.
    func planIfDue(_ workspace: WorkspaceConfig, now: Date = Date()) async {
        let name = workspace.name
        guard workspace.planning.enabled, state.workspaces[name]?.planningRun == nil, !planningBusy.contains(name)
        else { return }
        let record = planning[name]
        if let running = record.running, AgentRunner.isRunning(pid: running.pid, startedAt: running.processStartedAt) {
            return
        }
        let runs = state.planningRuns(workspace: name, planning: record)
        guard PlanningSchedule.isDue(last: PlanningSchedule.last(runs), now: now) else { return }

        planningBusy.insert(name)
        defer { planningBusy.remove(name) }
        let run: PlanningRun
        do {
            run = try await PlanningJob(workspace: workspace, runner: planningRunner)
                .prepare(since: PlanningSchedule.since(runs), linear: LinearClient(apiKey: workspace.apiKey), now: now)
        } catch {
            if firstReport("[\(name)] planning: \(error)") {
                log("Could not start the planning job, retrying each poll: \(error) (logged once)", workspace: name)
            }
            return
        }
        launchPlanning(run, mode: .start, workspace: workspace)
    }

    private func launchPlanning(_ run: PlanningRun, mode: LaunchMode, workspace: WorkspaceConfig) {
        let name = workspace.name
        do {
            let (launched, process) = try planningRunner.launch(run, mode: mode, workspace: name) { [run] status in
                Task { await self.finishPlanning(run, status: status, workspace: workspace) }
            }
            planningProcesses[name] = process
            state.startPlanning(launched, workspace: name)
            save()
            log(mode == .resume ? "Resuming the planning job" : "Started the planning job in \(run.worktreePath)", workspace: name)
            log("  Session: \(run.sessionId)", workspace: name)
            log("  Log: \(planningRunner.log(workspace: name))", workspace: name)
        } catch {
            log("Could not launch the planning job: \(error)", workspace: name)
            state.finishPlanning(
                PlanningRunRecord(
                    sessionId: run.sessionId, startedAt: run.startedAt, endedAt: Date(),
                    error: "Could not launch Claude: \(error)"),
                workspace: name)
            save()
            planningRunner.cleanUp(run.sessionId)
        }
    }

    private func recoverPlanning(_ run: PlanningRun, workspace: WorkspaceConfig) {
        let name = workspace.name
        switch planningRunner.recovery(for: run) {
        case .finished(let status):
            log("The planning job finished while the daemon was stopped", workspace: name)
            Task { await finishPlanning(run, status: status, workspace: workspace) }
        case .adopt:
            log("The planning job is still running (pid \(run.pid ?? 0)); waiting for it", workspace: name)
            if let source = planningRunner.watch(run, onExit: { status in
                Task { await self.finishPlanning(run, status: status, workspace: workspace) }
            }) {
                planningWatchers[name] = source
            }
        case .waiting, .requeue:
            log("The planning job was interrupted; resuming it", workspace: name)
            var resumed = run
            resumed.pid = nil
            resumed.processStartedAt = nil
            resumed.resumes += 1
            launchPlanning(resumed, mode: planningRunner.launchMode(for: resumed), workspace: workspace)
        case .abandon:
            log("Giving up on the planning job after \(run.resumes) resumes", workspace: name)
            Task { await finishPlanning(run, status: nil, workspace: workspace) }
        }
    }

    /// Stores what a planning job proposes, through the proposal store's
    /// rules, and records the job.
    private func finishPlanning(_ run: PlanningRun, status: Int32?, workspace: WorkspaceConfig) async {
        let name = workspace.name
        planningProcesses[name] = nil
        planningWatchers[name] = nil
        // A job is finished once; a late duplicate notice finds nothing to do.
        guard state.workspaces[name]?.planningRun?.sessionId == run.sessionId else { return }
        state.workspaces[name]?.planningRun = nil
        planningBusy.insert(name)
        defer { planningBusy.remove(name) }

        var (record, ingest) = PlanningJob(workspace: workspace, runner: planningRunner).finish(run, status: status)
        for refusal in ingest.refused {
            log("Planning job: refused \(refusal)", workspace: name)
        }
        for draft in ingest.drafts {
            if await propose(draft, workspace: workspace) != nil {
                record.proposed += 1
            } else {
                record.skipped += 1
            }
        }
        var summary = record.error.map { "The planning job failed: \($0)" }
            ?? "The planning job ended: \(record.proposed) proposed, \(record.skipped) skipped"
        if let usage = record.usage { summary += ", \(StatusSummary.compact(usage.tokens)) tokens" }
        log(summary, workspace: name)
        state.finishPlanning(record, workspace: name)
        save()
        planningRunner.cleanUp(run.sessionId)
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
