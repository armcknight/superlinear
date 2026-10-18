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
    /// The agents recovered after the usage limit stopped them.
    private var usageLimitRecoveries = UsageLimitRecoveries()
    /// The Linear user of each workspace's API key, whose reactions answer
    /// proposals, once looked up.
    private var linearViewers: [String: LinearUser.ID] = [:]
    /// Whether each workspace's repository is private, once looked up. Only
    /// private ones are stopped by the GitHub Actions spending limit.
    private var repositoryPrivate: [String: Bool] = [:]
    /// Whether each failed CI run attempt was stopped by the spending limit,
    /// by repository, run ID and attempt, so its annotations are read once.
    private var stopClassifications: [String: Bool] = [:]
    /// How often the daemon looks at the Claude pause, to check whether the
    /// limit was lifted and to end it at the reset time.
    private static let claudePauseTick: TimeInterval = 60
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
    /// Whether a roadmap is being built, and whether another planning job
    /// ended meanwhile, so it is to be built again once this one ends.
    private var roadmapBuilding = false
    private var roadmapAgain = false
    /// Failed workflow runs already screened for a proposal, so that each is
    /// screened once rather than searched for in Linear every poll.
    private var screenedWorkflowRuns: Set<String> = []
    private let commentRunner = CommentSessionRunner()
    /// The owner's comments waiting for a read-only session, by workspace.
    private var commentQuestions: [String: [CommentQuestion]] = [:]
    /// Workspaces whose comments a session is answering now.
    private var answeringComments: Set<String> = []
    /// Comments queued or being answered, by workspace, comment and text, so
    /// a poll does not queue one twice.
    private var queuedComments: Set<String> = []
    /// Failed sessions by comment, after `maxAnswerFailures` of which the
    /// comment is taken as handled rather than tried each poll.
    private var answerFailures: [String: Int] = [:]
    static let maxAnswerFailures = 3

    init(config: Config) {
        self.config = config
        self.state = State.load()
        self.planning = PlanningRecord.load()
    }

    func run() async throws {
        print("[superlinear] Starting with \(config.workspaces.count) workspace(s)")

        recoverRuns()
        sweepWorktrees()
        // `superlinear roadmap` only shows what the daemon built, so build
        // one now when there is none.
        if RoadmapRecord.load().roadmaps[RoadmapRecord.key(config.workspaces.map(\.name))] == nil { rebuildRoadmap() }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for workspace in config.workspaces {
                group.addTask {
                    await self.runWorkspaceLoop(workspace)
                }
            }
            group.addTask {
                await self.runClaudePauseLoop()
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
    func enqueueAgent(
        for issue: LinearIssue, workspace: WorkspaceConfig, queuedAt: Date, stack: StackBase?, comments: CommentContext? = nil
    ) {
        let run = AgentRun(
            issueId: issue.id.rawValue,
            identifier: issue.identifier,
            branchName: issue.branchName,
            sessionId: UUID().uuidString.lowercased(),
            queuedAt: queuedAt,
            stack: stack,
            comments: comments
        )
        state.markProcessed(issue.id.rawValue, workspace: workspace.name)
        state.recordRun(run, workspace: workspace.name)
        if let stack {
            log("Queued \(issue.identifier): \(issue.title), stacked on \(stack.identifier)'s pull request \(stack.url)",
                workspace: workspace.name)
        } else {
            log("Queued \(issue.identifier): \(issue.title)", workspace: workspace.name)
        }
        save()
        fillSlots()
    }

    /// Queues again an issue whose agent the Claude usage limit stopped before
    /// the daemon could pause it. It goes first, as a run the limit stopped
    /// does, resumes `sessionId` when that session exists, and is not a new
    /// start: the issue is not moved in Linear again.
    func requeueStoppedAtUsageLimit(_ issue: LinearIssueStatus, sessionId: String?, workspace: WorkspaceConfig) {
        guard state.workspaces[workspace.name]?.inFlight[issue.id] == nil,
              state.workspaces[workspace.name]?.pendingMerges[issue.id] == nil
        else { return }
        let now = Date()
        var run = AgentRun(
            issueId: issue.id,
            identifier: issue.identifier,
            branchName: issue.branchName,
            sessionId: sessionId ?? UUID().uuidString.lowercased(),
            queuedAt: now
        )
        run.launchedAt = now
        run.usageLimited = true
        state.recordRun(run, workspace: workspace.name)
        let how = sessionId.map { "resumes session \($0)" } ?? "starts a new session"
        log("\(issue.identifier) stopped at the Claude usage limit before it could be paused; queued again, it \(how)", workspace: workspace.name)
        save()
        fillSlots()
    }

    /// Whether to recover the agent for `issueId` that stopped at the usage
    /// limit, given when its log was last written. Each log is recovered
    /// once: a relaunch that fails before it writes the log again leaves the
    /// old limit message, which would otherwise queue the issue every poll.
    func claimUsageLimitRecovery(issueId: LinearIssue.ID, logModified: Date?) -> Bool {
        usageLimitRecoveries.claim(issueId: issueId, logModified: logModified)
    }

    /// Issues the daemon queued an agent for.
    func processedIssueIds(workspace: String) -> Set<LinearIssue.ID> {
        Set((state.workspaces[workspace]?.processedIssueIds ?? []).map(LinearIssue.ID.init(rawValue:)))
    }

    /// Queues an agent to address new reviews and comments on the pull
    /// request of an issue awaiting its merge. It works in the issue's existing worktree, under a
    /// new Claude session, and the issue awaits its merge again once it ends.
    /// With `comments`, the owner's new comments on the issue in Linear,
    /// the agent acts on them too, and they count as handled.
    func enqueueReview(
        of pending: PendingMerge, pullRequest: PullRequest, feedback: [PullRequestFeedback]? = nil,
        workspace: WorkspaceConfig, comments: CommentTriage.Comments? = nil
    ) {
        // The watch may have ended while the reviews were being read.
        guard state.workspaces[workspace.name]?.pendingMerges[pending.issueId] != nil else { return }
        var context: CommentContext?
        if let comments {
            let fresh = stillFresh(comments.fresh, key: .init(rawValue: pending.issueId), workspace: workspace.name)
            // Handled meanwhile: an agent is queued only for the pull request's feedback.
            guard !fresh.isEmpty || feedback != nil else { return }
            if !fresh.isEmpty {
                context = CommentContext(
                    thread: comments.context.thread, new: fresh.map { PromptComment($0.comment, previousBody: $0.previousBody) })
                state.handleComments(fresh, key: .init(rawValue: pending.issueId), since: Date(), workspace: workspace.name)
            }
        }
        let run = AgentRun(
            issueId: pending.issueId,
            identifier: pending.identifier,
            branchName: pending.branchName,
            sessionId: UUID().uuidString.lowercased(),
            queuedAt: Date(),
            review: ReviewRequest(number: pullRequest.number, url: pullRequest.url, feedback: feedback),
            stack: pending.stack,
            comments: context
        )
        state.startReview(run, workspace: workspace.name)
        let what = context == nil ? "the feedback on" : "the owner's comments in Linear, and any feedback on,"
        log("Queued \(pending.identifier) to address \(what) \(pullRequest.url)", workspace: workspace.name)
        save()
        fillSlots()
    }

    /// Queues a new agent, in the issue's worktree, to act on the owner's
    /// comments on an issue whose last agent ended without a pull request.
    /// Once it ends, the issue awaits its pull request again.
    func enqueueCommentAgent(_ comments: CommentTriage.Comments, workspace: WorkspaceConfig) {
        let name = workspace.name
        guard let ended = state.workspaces[name]?.endedAgents[comments.issueId],
              state.workspaces[name]?.inFlight[ended.issueId.rawValue] == nil,
              state.workspaces[name]?.pendingMerges[ended.issueId.rawValue] == nil
        else { return }
        let fresh = stillFresh(comments.fresh, key: .init(ended.issueId), workspace: name)
        guard !fresh.isEmpty else { return }
        let run = AgentRun(
            issueId: ended.issueId.rawValue,
            identifier: ended.identifier,
            branchName: ended.branchName,
            sessionId: UUID().uuidString.lowercased(),
            queuedAt: Date(),
            comments: CommentContext(thread: comments.context.thread, new: fresh.map { PromptComment($0.comment, previousBody: $0.previousBody) })
        )
        state.handleComments(fresh, key: .init(ended.issueId), since: Date(), workspace: name)
        state.workspaces[name]?.endedAgents[ended.issueId] = nil
        state.recordRun(run, workspace: name)
        log("Queued \(ended.identifier) to act on \(fresh.count) comment(s) from the owner in Linear; its last agent "
            + "opened no pull request", workspace: name)
        save()
        fillSlots()
    }

    /// Those of `comments` that the ledger does not have as handled with
    /// the text they have now: another task may have handled them since the
    /// poll read the ledger.
    private func stillFresh(_ comments: [FreshComment], key: CommentLedger.Key, workspace: String) -> [FreshComment] {
        let handled = state.workspaces[workspace]?.commentLedgers[key]?.handled ?? [:]
        return comments.filter { handled[$0.comment.id] != $0.comment.body }
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
            ),
            stack: current.stack
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
    /// None launches while the Claude usage limit pauses sessions; queued runs
    /// keep their places until it ends.
    private func fillSlots() {
        guard !recovering, claudeAvailable(now: Date()) else { return }
        if let until = launchesPausedUntil {
            guard Date() >= until else { return }
            launchesPausedUntil = nil
        }
        while processes.count + watchers.count < config.maxConcurrentAgents {
            let queued = state.workspaces.flatMap { name, workspaceState in
                workspaceState.inFlight.values.map { (name, $0) }
            }.filter { name, _ in workspace(named: name) != nil }
            guard let (name, run) = AgentRunner.nextQueued(queued), let workspace = workspace(named: name) else { break }
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
        // A run stopped by the usage limit before Claude saved its session
        // starts it again, but the issue started already.
        let firstLaunch = run.launchedAt == nil
        do {
            try FollowUpFile.ignore(repoPath: repoPath)
        } catch {
            if firstReport("ignore \(repoPath)") {
                log("Could not add \(FollowUpFile.excludeLine) to git's info/exclude in \(repoPath): \(error)", workspace: workspace.name)
            }
        }
        do {
            var run = run
            run.launchedAt = run.launchedAt ?? Date()
            run.usageLimited = nil
            // A stacked branch starts from the lower pull request's head on
            // the remote, which `work start` then adopts. Only a new issue's
            // run creates it; a review or conflict run finds it there.
            if var stack = run.stack, run.review == nil, run.conflict == nil,
               let head = try Stacking.createBranch(run.branchName, from: stack.branch, repoPath: repoPath) {
                stack.baseHead = head
                run.stack = stack
            }
            let (launched, process) = try runner.launch(run, mode: mode, repoPath: repoPath, apiKey: workspace.apiKey) { [run] status in
                Task { await self.finish(run, status: status, workspace: workspace.name) }
            }
            processes[run.issueId] = process
            state.recordRun(launched, workspace: workspace.name)
            log(mode == .resume ? "Resuming \(run.identifier)" : "Starting \(run.identifier)", workspace: workspace.name)
            if run.review == nil, run.conflict == nil, !run.answersComments, mode == .start, run.resumes == 0, firstLaunch {
                state.recordActivity(
                    ActivityEvent(time: Date(), kind: .agentStarted, identifier: run.identifier), workspace: workspace.name)
                if workspace.selection == .ready { markStarted(run, workspace: workspace) }
            }
            if let review = run.review {
                log("  Addressing the review on \(review.url)", workspace: workspace.name)
            }
            if run.review == nil, run.answersComments {
                log("  Acting on the owner's comments in Linear", workspace: workspace.name)
            }
            if let conflict = run.conflict {
                log("  Resolving the conflicts of \(conflict.url) with \(conflict.baseBranch)", workspace: workspace.name)
            }
            if let stack = run.stack {
                log("  Stacked on \(stack.identifier)'s pull request \(stack.url), from \(stack.branch)", workspace: workspace.name)
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
        guard let current = state.workspaces[workspace]?.inFlight[run.issueId], current.sessionId == run.sessionId
        else { return }

        if let hit = runner.usageLimitHit(for: run, now: Date()) {
            // Interrupted, not failed: it resumes in its session once the
            // pause ends, ahead of the queue, and counts no retry.
            state.recordRun(current.stoppedByUsageLimit(), workspace: workspace)
            // A status file left behind would read as finished after a restart.
            runner.cleanUp(run)
            log("\(run.identifier) stopped at the Claude usage limit; it resumes when the pause ends", workspace: workspace)
            pauseClaude(hit, now: Date())
            return
        }

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
        collectFollowUps(of: run, workspace: workspace)
        cleanWorktree(of: run, workspace: workspace)
    }

    /// Proposes the follow-ups the agent left in its worktree. Those that
    /// could not be proposed stay in the file for the next agent's exit; a
    /// malformed file stays for inspection.
    private func collectFollowUps(of run: AgentRun, workspace name: String) {
        guard let workspace = workspace(named: name) else { return }
        let repoPath = NSString(string: workspace.repoPath).expandingTildeInPath
        let pullRequest = run.review?.url ?? run.conflict?.url
            ?? state.linkedPullRequests(issueId: run.issueId, workspace: name).sorted().last
        Task.detached {
            guard let worktree = FollowUpFile.worktree(branch: run.branchName, repoPath: repoPath) else { return }
            let path = FollowUpFile.path(worktree: worktree)
            switch FollowUpFile.read(worktree: worktree) {
            case .none:
                return
            case .malformed(let reason):
                await self.log("Could not read \(run.identifier)'s follow-ups, kept for inspection at \(path): \(reason)", workspace: name)
            case .entries(let entries):
                let source = ProposalSource(
                    kind: .agentSession, value: run.sessionId, issue: run.identifier, pullRequest: pullRequest
                )
                let remaining = await self.proposeFollowUps(entries, of: run, source: source, workspace: workspace)
                do {
                    try FollowUpFile.keep(remaining, worktree: worktree)
                } catch {
                    await self.log("Could not update \(path): \(error)", workspace: name)
                }
            }
        }
    }

    /// Proposes a new issue for each follow-up, and returns those it could not.
    private func proposeFollowUps(
        _ entries: [FollowUp], of run: AgentRun, source: ProposalSource, workspace: WorkspaceConfig
    ) async -> [FollowUp] {
        log("\(run.identifier)'s agent reported \(entries.count) follow-up(s)", workspace: workspace.name)
        let linear = LinearClient(apiKey: workspace.apiKey)
        let issue: EditableIssue
        do {
            issue = try await linear.editableIssue(id: LinearIssue.ID(rawValue: run.issueId))
        } catch {
            log("Could not look up \(run.identifier) to propose its follow-ups: \(error)", workspace: workspace.name)
            return entries
        }
        var remaining: [FollowUp] = []
        for entry in entries {
            // Linear finds an issue by its identifier too. One it cannot find
            // is still named in the description.
            var related = issue.id
            if let identifier = entry.relatedIssue,
               let found = try? await linear.editableIssue(id: LinearIssue.ID(rawValue: identifier.rawValue)) {
                related = found.id
            }
            let draft = entry.draft(teamId: issue.teamId, relatedIssueId: related, agentIssue: run.identifier, source: source)
            do {
                try await propose(draft, workspace: workspace)
            } catch {
                log("Could not propose \(run.identifier)'s follow-up \"\(entry.title)\": \(error)", workspace: workspace.name)
                remaining.append(entry)
            }
        }
        return remaining
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

    // MARK: - Claude usage limit

    /// Pauses every Claude session until the limit resets, or extends the
    /// pause to a new reset time. Logs and notifies once per pause.
    private func pauseClaude(_ hit: ClaudeUsageLimit.Hit, now: Date) {
        if let pause = state.claudePause {
            state.claudePause = pause.extended(by: hit, now: now)
        } else {
            let pause = ClaudePause(hit: hit, now: now)
            state.claudePause = pause
            let until = StatusTime.clock(pause.until.rawValue, now: now)
            print("[\(ISO8601DateFormatter().string(from: now))] The Claude usage limit is reached; pausing Claude sessions "
                + "in every workspace until \(until), checking every \(Int(ClaudePause.checkInterval / 60)) minutes "
                + "whether it was lifted sooner")
            Notifier.post(title: Notifier.title, message: "Claude usage limit reached. Agents are paused until \(until).")
        }
        save()
    }

    /// Whether sessions may start now. Ends a pause whose reset time has passed.
    private func claudeAvailable(now: Date) -> Bool {
        guard let pause = state.claudePause else { return true }
        guard pause.isOver(now: now) else { return false }
        endClaudePause("its reset time has passed")
        return true
    }

    /// Remembers that Fable's limit is used up, so project-management
    /// sessions run on the fallback model until it resets.
    private func recordFableLimit(_ hit: ClaudeUsageLimit.Hit, now: Date, workspace: String) {
        state.recordFableLimit(hit, now: now)
        save()
        let until = state.fableLimit.map { StatusTime.clock($0.until.rawValue, now: now) } ?? "its reset"
        log("Fable's usage limit is reached; planning and comment answers run on \(PlanningModel.fallback.rawValue) "
            + "until \(until)", workspace: workspace)
    }

    private func endClaudePause(_ reason: String) {
        guard state.claudePause != nil else { return }
        state.claudePause = nil
        save()
        let waiting = state.queuedRuns.count
        print("[\(ISO8601DateFormatter().string(from: Date()))] The Claude pause ended: \(reason); "
            + "resuming \(waiting) waiting session(s)")
        Notifier.post(title: Notifier.title, message: "Claude usage limit lifted. Agents resume.")
    }

    /// Ends the Claude pause at once, as `superlinear resume` asks through
    /// SIGUSR1, and starts the waiting sessions.
    func resumeClaude() {
        guard state.claudePause != nil else {
            print("[superlinear] Asked to resume, but Claude sessions are not paused")
            return
        }
        endClaudePause("superlinear resume")
        fillSlots()
    }

    /// While sessions are paused: ends the pause at its reset time, and every
    /// `ClaudePause.checkInterval` runs a very small session to see whether the
    /// limit was lifted sooner.
    private func runClaudePauseLoop() async {
        while !Task.isCancelled {
            if let pause = state.claudePause {
                let now = Date()
                if pause.isOver(now: now) {
                    fillSlots()
                } else if pause.checkDue(now: now) {
                    await checkClaudePause()
                }
            }
            do {
                try await Task.sleep(for: .seconds(Self.claudePauseTick))
            } catch {
                break
            }
        }
    }

    private func checkClaudePause() async {
        // The check belongs to no workspace and reads no Linear, so it gets no key.
        let check = await ClaudePause.check(environment: LinearKey.withoutKey(ProcessInfo.processInfo.environment))
        // It may have ended while the check ran.
        guard let pause = state.claudePause else { return }
        let now = Date()
        guard let after = pause.after(check, now: now) else {
            endClaudePause("a check found the limit lifted before its reset time")
            fillSlots()
            return
        }
        state.claudePause = after
        save()
        let timestamp = ISO8601DateFormatter().string(from: now)
        switch check {
        case .limited:
            print("[\(timestamp)] The Claude usage limit still holds; paused until \(StatusTime.clock(after.until.rawValue, now: now))")
        case .failed(let message):
            print("[\(timestamp)] Could not check the Claude usage limit, trying again in "
                + "\(Int(ClaudePause.checkInterval / 60)) minutes: \(message)")
        case .lifted:
            break
        }
    }

    // MARK: - GitHub Actions spending limit

    /// Whether the workspace's repository is private, looked up once.
    func repositoryIsPrivate(workspace: String, repoPath: String) throws -> Bool {
        if let known = repositoryPrivate[workspace] { return known }
        let isPrivate = try SpendingLimit.isPrivate(repoPath: repoPath)
        repositoryPrivate[workspace] = isPrivate
        return isPrivate
    }

    func stopClassification(_ key: String) -> Bool? {
        stopClassifications[key]
    }

    func recordStopClassification(_ stopped: Bool, key: String) {
        stopClassifications[key] = stopped
    }

    func spendingLimitStop(workspace: String) -> SpendingLimitStop? {
        state.workspaces[workspace]?.spendingLimit
    }

    /// Records the workspace's CI runs stopped by the spending limit, or nil
    /// when none are. Logs and notifies when a stop starts or ends.
    func recordSpendingLimitStop(_ stop: SpendingLimitStop?, workspace: String) {
        let before = state.workspaces[workspace]?.spendingLimit
        guard before != stop else { return }
        state.workspaces[workspace, default: WorkspaceState()].spendingLimit = stop
        save()
        switch (before, stop) {
        case (nil, let stop?):
            log("CI not started on \(stop.branches.sorted().joined(separator: ", ")): the GitHub Actions spending limit "
                + "is used up. Rerunning one stopped run each hour until its jobs start", workspace: workspace)
            Notifier.post(title: Notifier.title, message: "GitHub Actions spending limit reached in \(workspace). CI is not starting.")
        case (_?, nil):
            log("CI runs again: the GitHub Actions spending limit no longer stops it", workspace: workspace)
            Notifier.post(title: Notifier.title, message: "GitHub Actions spending limit lifted in \(workspace). CI runs again.")
        default:
            break
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

    /// Issues waiting on blockers or a human, which each poll checks again.
    func waitingIssueIds(workspace: String) -> Set<LinearIssue.ID> {
        state.workspaces[workspace]?.waitingIssueIds ?? []
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

    /// Lower pull requests first, so a change to one reaches the pull
    /// requests above it in the same poll, bottom-up.
    func pendingMerges(workspace: String) -> [PendingMerge] {
        state.pendingMerges(workspace: workspace).sorted {
            $0.stackDepth == $1.stackDepth ? $0.identifier.sortsBefore($1.identifier) : $0.stackDepth < $1.stackDepth
        }
    }

    /// The merge watches by issue identifier, for the blockers an issue might
    /// stack on: a blocker whose agent has ended and whose pull request the
    /// daemon follows.
    func pendingMergesByIdentifier(workspace: String) -> [LinearIssue.Identifier: PendingMerge] {
        state.pendingMergesByIdentifier(workspace: workspace)
    }

    /// The merge watch of the issue on `branch`, if any.
    func pendingMerge(branch: String, workspace: String) -> PendingMerge? {
        state.pendingMerge(branch: branch, workspace: workspace)
    }

    /// Records what the issue's pull request is stacked on now, or nil once
    /// it is on the default branch.
    func updateStack(_ stack: StackBase?, issueId: String, workspace: String) {
        state.updateStack(stack, issueId: issueId, workspace: workspace)
        save()
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

    // MARK: - Planning file

    /// Reads the planning file again, and takes in the proposals
    /// `superlinear plan` stored for the workspace.
    func takeInPlanning(workspace: String) {
        planning = PlanningRecord.load()
        if state.takeIn(planning[workspace], workspace: workspace, now: Date()) {
            log("Took in proposals from `superlinear plan`", workspace: workspace)
            save()
        }
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

    /// Whether the failed workflow run at `url` is yet to be screened, and
    /// marks it screened.
    func screenWorkflowRun(_ url: String) -> Bool {
        screenedWorkflowRuns.insert(url).inserted
    }

    /// Lets the next poll screen the run again, as after Linear failed.
    func unscreenWorkflowRun(_ url: String) {
        screenedWorkflowRuns.remove(url)
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
    /// Throws when Linear could not be searched for duplicates.
    @discardableResult
    func propose(_ draft: ProposalDraft, workspace: WorkspaceConfig) async throws -> Proposal? {
        let screening = try await proposalEngine(workspace).screen(draft, existing: state.proposals(workspace: workspace.name))
        let proposal: Proposal, applyNow: Bool
        switch screening {
        case .store(let stored, let now):
            (proposal, applyNow) = (stored, now)
        case .merge(let merged):
            // Unless it was put in Linear, or decided, while the screening waited.
            guard let current = state.proposals(workspace: workspace.name).first(where: { $0.id == merged.id }),
                  current.status == .pending, current.post == nil
            else {
                log("Not proposing \(draft.payload.kind.rawValue): it repeats proposal \(merged.id), which was put in Linear meanwhile", workspace: workspace.name)
                return nil
            }
            state.recordProposal(merged, workspace: workspace.name)
            save()
            log("Merged a \(draft.payload.kind.rawValue) proposal into \(merged.id), the same work: \(draft.reason)", workspace: workspace.name)
            return merged
        case .skip(let reason):
            log("Not proposing \(draft.payload.kind.rawValue): \(reason)", workspace: workspace.name)
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

    private func proposalEngine(_ workspace: WorkspaceConfig) -> ProposalEngine {
        ProposalEngine(
            workspace: workspace.name, autonomy: workspace.autonomy,
            linear: LinearClient(apiKey: workspace.apiKey), audit: AuditLog(), duplicates: ClaudeDuplicateJudge()
        )
    }

    // MARK: - Proposals in Linear

    /// Puts the workspace's pending proposals in Linear, reads the owner's
    /// answers to those there and applies or rejects them, and expires those
    /// unanswered for `proposalExpiryDays`. Pending `auto` proposals, whose
    /// write failed before, are tried again. A proposal from before proposals
    /// were reviewed in Linear is put there like any other.
    func reviewProposals(_ workspace: WorkspaceConfig, now: Date) async {
        let name = workspace.name
        let client = LinearClient(apiKey: workspace.apiKey)
        let poster = ProposalPoster(
            linear: client,
            specTeamId: { try await client.proposalTeamId(teamIds: workspace.teamIds) },
            specDocumentId: workspace.planning.specDocumentId, specDocumentURL: workspace.planning.specDocumentURL,
            expiryDays: workspace.proposalExpiryDays)

        for var proposal in state.proposals(workspace: name) where proposal.status == .pending && proposal.post == nil {
            if proposal.trust == .auto {
                proposal = await applyProposal(proposal, workspace: workspace)
                // Sent back for review, it goes to Linear like the rest.
                guard proposal.status == .pending, proposal.trust == .review, proposal.lastError == nil else { continue }
            }
            await post(proposal, poster: poster, workspace: workspace, now: now)
        }

        let posted = state.proposals(workspace: name).filter(\.isPosted)
        if !posted.isEmpty {
            do {
                let viewer = try await viewerId(workspace: workspace, client: client)
                let ids = Array(Set(posted.compactMap { $0.post?.issueId })).sorted()
                let snapshots = Dictionary(
                    try await client.proposalIssues(ids: ids).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                for proposal in posted {
                    guard let post = proposal.post else { continue }
                    let snapshot = snapshots[post.issueId]
                    switch ProposalAnswer.read(proposal, snapshot: snapshot, viewerId: viewer) {
                    case .none:
                        continue
                    case .approve:
                        log("Approved in Linear: \(proposal.kind.rawValue) \(proposal.id)", workspace: name)
                        let result = await applyProposal(proposal, workspace: workspace)
                        // A write that failed is tried again next poll, as the answer stands.
                        guard result.lastError == nil else { continue }
                        await settle(result, poster: poster, workspace: workspace, now: now)
                    case .reject(let reason):
                        state.rejectProposal(id: proposal.id, reason: reason, workspace: name, now: now)
                        save()
                        log("Rejected in Linear: \(proposal.kind.rawValue) \(proposal.id) (\(reason))", workspace: name)
                        if snapshot != nil, let rejected = state.proposals(workspace: name).first(where: { $0.id == proposal.id }) {
                            await settle(rejected, poster: poster, workspace: workspace, now: now)
                        }
                        if let original = snapshot?.duplicateOf {
                            await proposeMerge(proposal, into: original, client: client, workspace: workspace)
                        }
                    }
                }
            } catch {
                if firstReport("[\(name)] answers: \(error)") {
                    log("Could not read the answers to proposals in Linear, trying again each poll: \(error) (logged once)", workspace: name)
                }
            }
        }

        let expired = state.expireProposals(olderThanDays: workspace.proposalExpiryDays, workspace: name, now: now)
        guard !expired.isEmpty else { return }
        log("Expired \(expired.count) proposal(s) in Linear over \(workspace.proposalExpiryDays) days", workspace: name)
        save()
        for proposal in expired {
            await settle(proposal, poster: poster, workspace: workspace, now: now)
        }
    }

    /// Proposes to add the text of a proposed issue, which the owner marked
    /// a duplicate of `original` in Linear, to `original`, so that what it
    /// says is not lost. A failure is logged; the proposal stays rejected.
    private func proposeMerge(
        _ proposal: Proposal, into original: ProposalIssueSnapshot.Related, client: LinearClient, workspace: WorkspaceConfig
    ) async {
        guard proposal.kind == .createIssue, let post = proposal.post else { return }
        do {
            let text = try await client.editableIssue(id: post.issueId).description
            let issue = try await client.editableIssue(id: original.id)
            guard !issue.handsOff, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            try await propose(IssueMerge.draft(merging: proposal, text: text, into: issue), workspace: workspace)
        } catch {
            log("Could not propose to merge \(post.issueIdentifier ?? post.issueId.rawValue) into \(original.identifier): \(error)", workspace: workspace.name)
        }
    }

    /// Puts one proposal in Linear and records where. A failure is logged
    /// once, and the proposal tried again at the next poll.
    private func post(_ proposal: Proposal, poster: ProposalPoster, workspace: WorkspaceConfig, now: Date) async {
        let name = workspace.name
        do {
            let posted = try await poster.post(proposal, now: now)
            for warning in posted.warnings where firstReport("[\(name)] \(warning)") {
                log(warning + " (logged once)", workspace: name)
            }
            state.recordProposal(posted.proposal, workspace: name)
            save()
            if let post = posted.proposal.post {
                let form = post.form == .comment ? "a comment on \(post.issueIdentifier ?? post.issueId.rawValue)" : "issue \(post.issueIdentifier ?? post.issueId.rawValue)"
                log("Put \(proposal.kind.rawValue) \(proposal.id) in Linear as \(form)" + (post.url.map { ": \($0)" } ?? ""), workspace: name)
            } else if posted.proposal.status == .rejected {
                log("Rejected \(proposal.kind.rawValue) \(proposal.id): \(posted.proposal.rejectionReason ?? "no reason")", workspace: name)
            }
        } catch {
            if firstReport("[\(name)] post \(proposal.id): \(error)") {
                log("Could not put \(proposal.kind.rawValue) \(proposal.id) in Linear, trying again each poll: \(error) (logged once)", workspace: name)
            }
        }
    }

    /// Marks a decided proposal in Linear, or asks again for one sent back
    /// for review, and records its new post.
    private func settle(_ proposal: Proposal, poster: ProposalPoster, workspace: WorkspaceConfig, now: Date) async {
        let name = workspace.name
        let othersPending = state.proposals(workspace: name).contains {
            $0.id != proposal.id && $0.isPosted && $0.post?.issueId == proposal.post?.issueId
        }
        do {
            let settled = try await poster.settle(proposal, othersPending: othersPending, now: now)
            if settled != proposal {
                state.recordProposal(settled, workspace: name)
                save()
            }
            if settled.status == .pending, let post = settled.post {
                log("Asked again in Linear for \(proposal.kind.rawValue) \(proposal.id)" + (post.url.map { ": \($0)" } ?? ""), workspace: name)
            }
        } catch {
            if firstReport("[\(name)] settle \(proposal.id) \(proposal.status.rawValue): \(error)") {
                log("Could not mark \(proposal.kind.rawValue) \(proposal.id) as \(proposal.status.rawValue) in Linear: \(error) (logged once)", workspace: name)
            }
        }
    }

    /// The Linear user of the workspace's API key, looked up once.
    func viewerId(workspace: WorkspaceConfig, client: LinearClient) async throws -> LinearUser.ID {
        if let viewer = linearViewers[workspace.name] { return viewer }
        let viewer = try await client.viewerId()
        linearViewers[workspace.name] = viewer
        return viewer
    }

    // MARK: - The owner's comments

    /// What the comment check needs from the state file.
    func commentInputs(workspace: String) -> CommentTriage.Inputs {
        let workspaceState = state.workspaces[workspace] ?? WorkspaceState()
        return CommentTriage.Inputs(
            proposals: workspaceState.proposals, pendingMerges: Array(workspaceState.pendingMerges.values),
            ended: Array(workspaceState.endedAgents.values), runs: Array(workspaceState.inFlight.values),
            ledgers: workspaceState.commentLedgers)
    }

    func recordCommentWatch(_ plan: CommentTriage.Plan, workspace: String) {
        state.recordCommentWatch(plan, workspace: workspace)
        save()
    }

    /// Records that the issue's last agent ended without a pull request, so
    /// the owner's next comment on it queues a new agent.
    func recordEndedAgent(_ ended: EndedAgent, workspace: String) {
        guard state.workspaces[workspace]?.endedAgents[ended.issueId] == nil else { return }
        state.workspaces[workspace, default: WorkspaceState()].endedAgents[ended.issueId] = ended
        save()
    }

    func endedAgentIds(workspace: String) -> Set<LinearIssue.ID> {
        Set(state.workspaces[workspace]?.endedAgents.keys.map { $0 } ?? [])
    }

    /// The owner's questions on the spec document to answer. The document's
    /// first check counts only comments from then on.
    func specQuestions(_ document: DocumentComments, url: String?, viewer: LinearUser.ID, workspace: String, now: Date) -> [CommentQuestion] {
        let key = CommentLedger.Key.document(document.id)
        guard let ledger = state.workspaces[workspace]?.commentLedgers[key] else {
            state.workspaces[workspace, default: WorkspaceState()].commentLedgers[key] = CommentLedger(since: now)
            save()
            return []
        }
        return CommentQuestion.spec(document, url: url, ledger: ledger, viewer: viewer)
    }

    /// Queues the questions for read-only sessions, one at a time per
    /// workspace, in the background, so the poll does not wait for them.
    func queueCommentAnswers(_ questions: [CommentQuestion], workspace: WorkspaceConfig) {
        let name = workspace.name
        for question in questions {
            guard queuedComments.insert(Self.commentKey(question, workspace: name)).inserted else { continue }
            commentQuestions[name, default: []].append(question)
        }
        guard !answeringComments.contains(name), !(commentQuestions[name] ?? []).isEmpty else { return }
        answeringComments.insert(name)
        Task { await self.answerQueuedComments(workspace) }
    }

    private static func commentKey(_ question: CommentQuestion, workspace: String) -> String {
        "\(workspace) \(question.comment.comment.id) \(question.comment.comment.body.hashValue)"
    }

    private func answerQueuedComments(_ workspace: WorkspaceConfig) async {
        let name = workspace.name
        defer { answeringComments.remove(name) }
        while let question = commentQuestions[name]?.first {
            commentQuestions[name]?.removeFirst()
            defer { queuedComments.remove(Self.commentKey(question, workspace: name)) }
            // The Claude pause holds them back; the next poll after it finds them again.
            guard claudeAvailable(now: Date()) else {
                for other in commentQuestions[name] ?? [] { queuedComments.remove(Self.commentKey(other, workspace: name)) }
                commentQuestions[name] = []
                return
            }
            guard !stillFresh([question.comment], key: question.key, workspace: name).isEmpty else { continue }
            await answer(question, workspace: workspace)
        }
    }

    /// Runs a read-only session on the question and writes its answer in
    /// Linear. The comment counts as handled once the reply is posted; a
    /// session stopped at the usage limit pauses Claude and leaves it for
    /// after the pause.
    private func answer(_ question: CommentQuestion, workspace: WorkspaceConfig) async {
        let name = workspace.name
        let repoPath = NSString(string: workspace.repoPath).expandingTildeInPath
        let worktree = PlanningGit.defaultBranch(repoPath: repoPath).flatMap { PlanningGit.worktree(of: $0, repoPath: repoPath) } ?? repoPath
        let linear = LinearClient(apiKey: workspace.apiKey)
        var openIssues: [String] = []
        if case .spec = question.subject, let issues = try? await linear.planningIssues(teamIds: workspace.watchedTeams) {
            openIssues = issues.map { "\($0.identifier) [\($0.stateName)] \($0.title)" }
        }
        // The issues the comment names go in the prompt, so a question such
        // as "is this a duplicate of X?" needs no tool call.
        var namedIssues: [PlanningIssue] = []
        do {
            let teamKeys = Set(try await linear.planningTeams(ids: []).map(\.key))
            let identifiers = CommentAnswerPrompt.namedIdentifiers(question, teamKeys: teamKeys)
            if !identifiers.isEmpty {
                let found = try await linear.namedIssues(identifiers: identifiers)
                namedIssues = identifiers.compactMap { identifier in found.first { $0.identifier == identifier } }
            }
        } catch {
            log("Could not read the issues the comment on \(question.location) names; answering without them: \(error)", workspace: name)
        }
        var sessionId = ClaudeSession.ID(rawValue: UUID().uuidString.lowercased())
        let startedAt = Date()
        var model = state.planningModel(now: startedAt)
        log("Answering the owner's comment on \(question.location) in session \(sessionId), on \(model.rawValue)", workspace: name)
        var session: CommentSessionRunner.Session
        do {
            let prompt = CommentAnswerPrompt.render(question, openIssues: openIssues, namedIssues: namedIssues)
            session = try await commentRunner.run(prompt: prompt, sessionId: sessionId, model: model, worktree: worktree, workspace: name, apiKey: workspace.apiKey)
            // At Fable's limit, the question is asked again on the fallback, in a new session.
            if model == .fable, let hit = ClaudeUsageLimit.hit(in: session.output, now: Date(), timeZone: .current) {
                recordFableLimit(hit, now: Date(), workspace: name)
                model = PlanningModel.fallback
                sessionId = ClaudeSession.ID(rawValue: UUID().uuidString.lowercased())
                log("Answering the comment on \(question.location) again in session \(sessionId), on \(model.rawValue)", workspace: name)
                session = try await commentRunner.run(prompt: prompt, sessionId: sessionId, model: model, worktree: worktree, workspace: name, apiKey: workspace.apiKey)
            }
        } catch {
            failed(question, "Could not start Claude: \(error)", workspace: name)
            return
        }
        var record = CommentAnswerRecord(
            sessionId: sessionId, startedAt: startedAt, endedAt: Date(), location: question.location,
            usage: planningRunner.usage(sessionId))
        defer {
            state.recordCommentAnswer(record, workspace: name)
            save()
        }
        if let hit = ClaudeUsageLimit.hit(in: session.output, now: Date(), timeZone: .current) {
            record.error = "stopped at the Claude usage limit"
            log("The session answering the comment on \(question.location) stopped at the Claude usage limit; "
                + "it is answered after the pause", workspace: name)
            pauseClaude(hit, now: Date())
            return
        }
        let answer: CommentAnswer
        do {
            guard session.status == 0 else {
                throw CommentAnswerError.noAnswer("Claude exited \(session.status.map(String.init) ?? "without a status")")
            }
            answer = try CommentAnswer.parse(session.output)
        } catch {
            record.error = "\(error)"
            failed(question, "\(error); see \(commentRunner.log(workspace: name))", workspace: name)
            return
        }

        let responder = CommentResponder(linear: linear, specDocumentURL: workspace.planning.specDocumentURL)
        do {
            switch question.subject {
            case .proposal(let asked, _):
                // The owner may have answered the proposal while the session ran.
                guard let proposal = state.proposals(workspace: name).first(where: { $0.id == asked.id }), proposal.isPosted else {
                    log("Not replying on \(question.location): the proposal was answered meanwhile", workspace: name)
                    break
                }
                let answered = try await responder.answer(question, about: proposal, with: answer, now: Date())
                if let revised = answered.revised {
                    state.recordProposal(revised, workspace: name)
                    log("Changed \(proposal.kind.rawValue) \(proposal.id) as the owner asked", workspace: name)
                }
                log("Replied on \(question.location)" + (answered.reply.url.map { ": \($0)" } ?? ""), workspace: name)
            case .spec(let document, _):
                var proposal: Proposal?
                let asked = answer.revision.map { $0 != document.content } ?? false
                if asked, let text = answer.revision {
                    proposal = try await proposeSpecChange(text, document: document, question: question, workspace: workspace)
                }
                let reply = try await responder.reply(
                    to: question, text: CommentResponder.specReply(answer.answer, proposal: proposal, asked: asked))
                log("Replied on \(question.location)" + (reply.url.map { ": \($0)" } ?? ""), workspace: name)
            }
        } catch {
            record.error = "\(error)"
            failed(question, "Could not reply in Linear: \(error)", workspace: name)
            return
        }
        state.handleComments([question.comment], key: question.key, since: question.since, workspace: name)
        answerFailures[Self.commentKey(question, workspace: name)] = nil
        if let usage = record.usage { log("  The session used \(Stats.compact(usage.tokens)) tokens", workspace: name) }
    }

    /// Proposes the spec change a comment asked for, and puts it in Linear
    /// at once, so the reply can link it. Nil when the same change is
    /// pending or was rejected.
    private func proposeSpecChange(
        _ text: String, document: DocumentComments, question: CommentQuestion, workspace: WorkspaceConfig
    ) async throws -> Proposal? {
        let draft = CommentQuestion.specDraft(text, document: document, comment: question.comment.comment)
        guard let proposal = try await propose(draft, workspace: workspace) else { return nil }
        guard proposal.status == .pending, proposal.post == nil else { return proposal }
        let client = LinearClient(apiKey: workspace.apiKey)
        let poster = ProposalPoster(
            linear: client,
            specTeamId: { try await client.proposalTeamId(teamIds: workspace.teamIds) },
            specDocumentId: workspace.planning.specDocumentId, specDocumentURL: workspace.planning.specDocumentURL,
            expiryDays: workspace.proposalExpiryDays)
        await post(proposal, poster: poster, workspace: workspace, now: Date())
        return state.proposals(workspace: workspace.name).first { $0.id == proposal.id }
    }

    /// Logs a failed answer. After `maxAnswerFailures` the comment is taken
    /// as handled, so that one no session can answer is not tried forever.
    private func failed(_ question: CommentQuestion, _ reason: String, workspace: String) {
        let key = Self.commentKey(question, workspace: workspace)
        let failures = (answerFailures[key] ?? 0) + 1
        answerFailures[key] = failures
        guard failures >= Self.maxAnswerFailures else {
            log("Could not answer the comment on \(question.location), trying again next poll: \(reason)", workspace: workspace)
            return
        }
        log("Giving up on the comment on \(question.location) after \(failures) failed sessions: \(reason)", workspace: workspace)
        answerFailures[key] = nil
        state.handleComments([question.comment], key: question.key, since: question.since, workspace: workspace)
        save()
    }

    // MARK: - Planning

    /// Starts the workspace's planning job when planning is on, none is
    /// running, the daemon's or `superlinear plan`'s, Claude sessions are
    /// not paused at the usage limit, and something changed since the last
    /// one: the default branch moved, or issues were completed. See
    /// `PlanningGatherer.trigger`.
    func planIfDue(_ workspace: WorkspaceConfig, now: Date) async {
        let name = workspace.name
        guard workspace.planning.enabled, state.workspaces[name]?.planningRun == nil, !planningBusy.contains(name),
              claudeAvailable(now: now)
        else { return }
        let record = planning[name]
        if let running = record.running, AgentRunner.isRunning(pid: running.pid, startedAt: running.processStartedAt) {
            return
        }
        let history = state.planningRuns(workspace: name, planning: record)

        planningBusy.insert(name)
        defer { planningBusy.remove(name) }
        let linear = LinearClient(apiKey: workspace.apiKey)
        let trigger: PlanningTrigger
        let run: PlanningRun
        do {
            guard let found = try await PlanningGatherer(workspace: workspace, linear: linear).trigger(history: history) else { return }
            trigger = found
            run = try await PlanningJob(workspace: workspace, runner: planningRunner)
                .prepare(history: history, trigger: trigger, linear: linear, now: now)
        } catch {
            if firstReport("[\(name)] planning: \(error)") {
                log("Could not start the planning job, retrying each poll: \(error) (logged once)", workspace: name)
            }
            return
        }
        log("Starting the planning job: \(trigger)", workspace: name)
        launchPlanning(run, mode: .start, workspace: workspace)
    }

    private func launchPlanning(_ run: PlanningRun, mode: LaunchMode, workspace: WorkspaceConfig) {
        let name = workspace.name
        let model = state.planningModel(now: Date())
        var run = run
        run.model = model
        do {
            let (launched, process) = try planningRunner.launch(run, mode: mode, model: model, workspace: name, apiKey: workspace.apiKey) { [run] status in
                Task { await self.finishPlanning(run, status: status, workspace: workspace) }
            }
            planningProcesses[name] = process
            state.startPlanning(launched, workspace: name)
            save()
            log(mode == .resume ? "Resuming the planning job" : "Started the planning job in \(run.worktreePath)", workspace: name)
            log("  Session: \(run.sessionId), on \(model.rawValue)", workspace: name)
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
        let now = Date()
        // A job Fable's limit stopped resumes in its session on the fallback.
        if run.model == .fable, let hit = planningRunner.usageLimitHit(workspace: name, now: now) {
            recordFableLimit(hit, now: now, workspace: name)
            var resumed = run
            resumed.pid = nil
            resumed.processStartedAt = nil
            launchPlanning(resumed, mode: planningRunner.launchMode(for: resumed), workspace: workspace)
            return
        }
        state.workspaces[name]?.planningRun = nil
        planningBusy.insert(name)
        defer { planningBusy.remove(name) }

        var (record, ingest) = PlanningJob(workspace: workspace, runner: planningRunner).finish(run, status: status, now: Date())
        for refusal in ingest.refused {
            log("Planning job: refused \(refusal)", workspace: name)
        }
        for draft in ingest.drafts {
            do {
                if try await propose(draft, workspace: workspace) != nil {
                    record.proposed += 1
                } else {
                    record.skipped += 1
                }
            } catch {
                log("Could not check a \(draft.payload.kind.rawValue) proposal for duplicates: \(error)", workspace: name)
                record.skipped += 1
            }
        }
        var summary = record.error.map { "The planning job failed: \($0)" }
            ?? "The planning job ended: \(record.proposed) proposed, \(record.skipped) skipped"
        if let usage = record.usage { summary += ", \(Stats.compact(usage.tokens)) tokens" }
        log(summary, workspace: name)
        state.finishPlanning(record, workspace: name)
        save()
        planningRunner.cleanUp(run.sessionId)
        rebuildRoadmap()
    }

    // MARK: - Roadmap

    /// Rebuilds the roadmap of every workspace in the background, once a
    /// planning job ends, so `superlinear roadmap` is usually current. Jobs
    /// that end while one is being built lead to one more build after it.
    private func rebuildRoadmap() {
        guard !roadmapBuilding else {
            roadmapAgain = true
            return
        }
        guard claudeAvailable(now: Date()) else { return }
        roadmapBuilding = true
        let workspaces = config.workspaces
        let snapshot = state
        let model = state.planningModel(now: Date())
        Task {
            let say: @Sendable (String) -> Void = { message in
                print("[\(ISO8601DateFormatter().string(from: Date()))] [roadmap] \(message)")
            }
            let (outcome, limit) = await RoadmapBuilder().build(workspaces: workspaces, state: snapshot, model: model, say: say)
            self.finishRoadmap(outcome, fableLimit: limit)
        }
    }

    private func finishRoadmap(_ outcome: RoadmapBuilder.Outcome, fableLimit: ClaudeUsageLimit.Hit?) {
        roadmapBuilding = false
        if let fableLimit { recordFableLimit(fableLimit, now: Date(), workspace: "roadmap") }
        switch outcome {
        case .built(let roadmap):
            log("Rebuilt the roadmap: \(roadmap.steps.count) steps, \(roadmap.actions.count) actions for the owner", workspace: "roadmap")
        case .busy(let reason):
            log("Not rebuilding the roadmap: \(reason)", workspace: "roadmap")
        case .failed(let reason):
            log("Could not rebuild the roadmap: \(reason)", workspace: "roadmap")
        }
        if roadmapAgain {
            roadmapAgain = false
            rebuildRoadmap()
        }
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
