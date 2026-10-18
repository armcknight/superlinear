import Foundation

struct WorkspaceProcessor: Sendable {
    let workspace: WorkspaceConfig
    let daemon: Daemon

    func poll() async throws {
        let client = LinearClient(apiKey: workspace.apiKey)
        // Before the query, so an issue created while it runs is not missed.
        let pollTime = Date()

        await daemon.takeInPlanning(workspace: workspace.name)
        let candidates = try await fetchCandidates(client: client)
        let handled = await daemon.handledIssueIds(workspace: workspace.name)
        var plan = IssueSelection.plan(candidates, workspace: workspace, handled: handled, stackBases: [:])
        // Each step checks first, as one hitting the rate limit pauses the rest.
        let listing = PullRequestListing(repoPath: NSString(string: workspace.repoPath).expandingTildeInPath)
        if workspace.stacking, !plan.blocked.isEmpty, await daemon.gitHubAvailable() {
            let bases = await stackBases(for: plan, listing: listing)
            if !bases.isEmpty {
                plan = IssueSelection.plan(candidates, workspace: workspace, handled: handled, stackBases: bases)
            }
        }
        await daemon.recordWaiting(plan, workspace: workspace.name)

        if plan.start.isEmpty {
            log("No issues to start")
        } else {
            log("Found \(plan.start.count) issue(s) to start")
        }

        for (index, issue) in plan.start.enumerated() {
            // Apart, so they start in the plan's order.
            let queuedAt = pollTime.addingTimeInterval(Double(index) / 1000)
            await daemon.enqueueAgent(for: issue, workspace: workspace, queuedAt: queuedAt, stack: plan.stacked[issue.id])
        }

        await daemon.updateLastPoll(pollTime, workspace: workspace.name)
        await daemon.reviewProposals(workspace, now: Date())
        await daemon.planIfDue(workspace, now: Date())

        if await daemon.gitHubAvailable() { await linkRunningAgentsPullRequests(client: client, listing: listing) }
        if await daemon.gitHubAvailable() { await checkPullRequests(client: client, listing: listing) }
        if await daemon.gitHubAvailable() { await sweepStartedIssues(client: client, listing: listing) }
        if await daemon.gitHubAvailable() { await checkSpendingLimit(listing: listing) }
        if await daemon.gitHubAvailable() { await checkDefaultBranchWorkflows(client: client, repoPath: listing.repoPath) }
    }

    /// The pull requests the plan's blocked issues may stack on: for each
    /// issue with one open blocker whose agent has ended, that blocker's open
    /// pull request, when it is not a draft, its CI passes, and the stack
    /// stays within `maxStackDepth`. One `gh` call per such blocker.
    private func stackBases(for plan: IssueSelectionPlan, listing: PullRequestListing) async -> [LinearIssue.Identifier: StackBase] {
        let watched = await daemon.pendingMergesByIdentifier(workspace: workspace.name)
        let blockers = Set(plan.blocked.values.compactMap { $0.blockers.count == 1 ? $0.blockers.first : nil })
        var bases: [LinearIssue.Identifier: StackBase] = [:]
        for blocker in blockers.sorted() {
            guard let pending = watched[blocker] else { continue }
            let pullRequest: PullRequest?
            do {
                pullRequest = try await listing.checker.stackBase(branch: pending.branchName, repoPath: listing.repoPath)
            } catch {
                if await pausedForRateLimit(error, repoPath: listing.repoPath) { return bases }
                await logOnce("Could not look up \(blocker)'s pull request to stack on it: \(error)")
                continue
            }
            switch Stacking.base(on: pending, pullRequest: pullRequest, maxDepth: workspace.maxStackDepth) {
            case .success(let base):
                bases[blocker] = base
            case .failure(let reason):
                let dependents = plan.blocked.values.filter { $0.blockers == [blocker] }.map(\.identifier.rawValue).sorted()
                await logOnce("\(dependents.joined(separator: ", ")) cannot stack on \(blocker) yet: \(reason)")
            }
        }
        return bases
    }

    /// Finds the CI runs of open pull requests and of the default branch that
    /// the GitHub Actions spending limit stopped, in a private repository. While
    /// there are any, reruns the failed jobs of one each hour; once its jobs
    /// start, or those of a run the owner reran by hand, the limit was raised,
    /// and the others are rerun too.
    private func checkSpendingLimit(listing: PullRequestListing) async {
        let repoPath = listing.repoPath
        do {
            guard try await daemon.repositoryIsPrivate(workspace: workspace.name, repoPath: repoPath) else { return }
            var stop = await daemon.spendingLimitStop(workspace: workspace.name)
            let runs = try SpendingLimit.listRuns(in: repoPath)

            // A stopped run rerun since the last poll, by the daemon or by the
            // owner, tells whether the limit was raised. The probe is read
            // first, and waited for; the others only count once they ran.
            for watched in stop?.watched ?? [] {
                let current = runs.first { $0.databaseId == watched.id }
                let result = await SpendingLimit.probeResult(current, rerunFrom: watched.attempt) {
                    guard let current else { return nil }
                    return try? await wasStopped(current, repoPath: repoPath)
                }
                let isProbe = watched.id == stop?.probe?.id
                switch result {
                case .pending where isProbe:
                    return
                case .pending:
                    break
                case .started:
                    let who = isProbe ? "The rerun of" : "A rerun by hand of"
                    log("\(who) CI run \(watched.id) on \(watched.branch) started its jobs, so the spending limit was raised")
                    for other in stop?.othersToRerun(after: watched) ?? [] {
                        do {
                            try SpendingLimit.rerunFailedJobs(runId: other.id, in: repoPath)
                            log("  Reran the failed jobs of CI run \(other.id) on \(other.branch)")
                        } catch {
                            log("  Could not rerun CI run \(other.id) on \(other.branch): \(error)")
                        }
                    }
                    await daemon.recordSpendingLimitStop(nil, workspace: workspace.name)
                    return
                case .stillStopped where isProbe:
                    stop?.probe = nil
                case .stillStopped:
                    break
                }
            }

            let openBranches = try await listing.allPullRequests().filter { $0.state == .open }.compactMap(\.headRefName)
            let defaultBranch = Git.defaultBranch(in: repoPath)
            var stopped: [StoppedRun] = []
            for run in SpendingLimit.failingRuns(runs, branches: Set(openBranches + [defaultBranch].compactMap { $0 })) {
                if try await wasStopped(run, repoPath: repoPath) { stopped.append(StoppedRun(run)) }
            }
            let now = Date()
            stop = SpendingLimitStop.updated(stop, stopped: stopped, now: now)
            if var current = stop, let probe = current.runToProbe(now: now) {
                try SpendingLimit.rerunFailedJobs(runId: probe.id, in: repoPath)
                log("Reran the failed jobs of CI run \(probe.id) on \(probe.branch) to see whether the spending limit was raised")
                current.probe = probe
                current.lastRerunAt = now
                stop = current
            }
            await daemon.recordSpendingLimitStop(stop, workspace: workspace.name)
        } catch {
            if await pausedForRateLimit(error, repoPath: repoPath) { return }
            await logOnce("Could not check CI for the GitHub Actions spending limit: \(error)")
        }
    }

    /// Whether the spending limit stopped the run's latest attempt, from its
    /// annotations, read once per attempt.
    private func wasStopped(_ run: WorkflowRunSummary, repoPath: String) async throws -> Bool {
        let key = "\(repoPath)#\(run.databaseId):\(run.attempt ?? 1)"
        if let known = await daemon.stopClassification(key) { return known }
        let stopped = try SpendingLimit.wasStopped(runId: run.databaseId, in: repoPath)
        await daemon.recordStopClassification(stopped, key: key)
        return stopped
    }

    /// Proposes an issue for each workflow whose latest run on the default
    /// branch failed. Each failed run is screened once.
    private func checkDefaultBranchWorkflows(client: LinearClient, repoPath: String) async {
        let branch = Git.defaultBranch(in: repoPath) ?? "main"
        let runs: [WorkflowRun]
        do {
            let output = try await PullRequestChecker().run(WorkflowFailures.listArguments(branch: branch), in: repoPath)
            runs = try WorkflowFailures.decodeRuns(output)
        } catch {
            if await pausedForRateLimit(error, repoPath: repoPath) { return }
            await logOnce("Could not list the workflow runs on \(branch): \(error)")
            return
        }
        // A run the spending limit stopped is not a failure to propose: the
        // daemon reruns it once the limit is raised.
        let stopped = Set(await daemon.spendingLimitStop(workspace: workspace.name)?.runs.map(\.id) ?? [])
        var failing: [WorkflowRun] = []
        for run in WorkflowFailures.failing(runs) where !WorkflowFailures.isStopped(run, stopped: stopped) {
            if await daemon.screenWorkflowRun(run.url ?? "") { failing.append(run) }
        }
        guard !failing.isEmpty else { return }
        let teamId: LinearTeam.ID
        do {
            teamId = try await client.proposalTeamId(teamIds: workspace.teamIds)
        } catch {
            for run in failing { await daemon.unscreenWorkflowRun(run.url ?? "") }
            await logOnce("Could not find a team for proposals about failing workflows: \(error)")
            return
        }
        for run in failing {
            log("The \(run.workflowName ?? "unnamed") workflow fails on \(branch): \(run.url ?? "")")
            do {
                try await daemon.propose(WorkflowFailures.draft(run, branch: branch, teamId: teamId), workspace: workspace)
            } catch {
                await daemon.unscreenWorkflowRun(run.url ?? "")
                await logOnce("Could not propose an issue for the failing \(run.workflowName ?? "unnamed") workflow: \(error)")
            }
        }
    }

    /// Proposes an issue for each `TODO` or `FIXME` line the merged pull
    /// request added that names no issue. Tried once, as the watch ends.
    private func proposeAddedTodos(of pullRequest: PullRequest, pending: PendingMerge, client: LinearClient, repoPath: String) async {
        let todos: [AddedTodos.Todo]
        do {
            let diff = try await PullRequestChecker().run(AddedTodos.diffArguments(number: pullRequest.number), in: repoPath)
            todos = AddedTodos.parse(diff: String(decoding: diff, as: UTF8.self))
        } catch {
            _ = await pausedForRateLimit(error, repoPath: repoPath)
            log("  Could not read the diff of \(pullRequest.url) for added TODOs: \(error)")
            return
        }
        guard !todos.isEmpty else { return }
        log("  \(pullRequest.url) added \(todos.count) TODO or FIXME line(s)")
        let issue: EditableIssue
        do {
            issue = try await client.editableIssue(id: LinearIssue.ID(rawValue: pending.issueId))
        } catch {
            log("  Could not look up \(pending.identifier) to propose its added TODOs: \(error)")
            return
        }
        for todo in todos {
            let draft = AddedTodos.draft(
                todo, pullRequest: pullRequest, agentIssue: pending.identifier, issueId: issue.id, teamId: issue.teamId
            )
            do {
                try await daemon.propose(draft, workspace: workspace)
            } catch {
                log("  Could not propose an issue for the \(todo.marker.rawValue) at \(todo.file):\(todo.line): \(error)")
            }
        }
    }

    /// The issues an agent might start on this poll: in `new` mode, those
    /// created since the last poll, and the waiting ones checked again; in
    /// `ready` mode, every open issue in a ready state, which includes every
    /// waiting issue still worth waiting for.
    private func fetchCandidates(client: LinearClient) async throws -> [LinearIssue] {
        switch workspace.selection {
        case .ready:
            log("Polling issues in \(workspace.readyStates.map(\.rawValue).joined(separator: ", "))")
            return try await client.fetchReadyIssues(states: workspace.readyStates, teamIds: workspace.teamIds)
        case .new:
            let lastPoll = await daemon.lastPollTimestamp(workspace: workspace.name)
            if lastPoll == .distantPast {
                log("First poll: only issues created from now on start agents")
            } else {
                log("Polling since \(ISO8601DateFormatter().string(from: lastPoll))")
            }
            return try await Self.newCandidates(
                lastPoll: lastPoll,
                waiting: await daemon.waitingIssueIds(workspace: workspace.name),
                created: { try await client.fetchNewIssues(since: $0, teamIds: workspace.teamIds) },
                byIds: { try await client.fetchCandidates(ids: $0) }
            )
        }
    }

    /// The `new` mode candidates: issues created since `lastPoll`, then the
    /// `waiting` ones not among them. A workspace's first poll, with no last
    /// poll, fetches no created issues rather than every open one, so only
    /// issues created after it start.
    static func newCandidates(
        lastPoll: Date, waiting: Set<LinearIssue.ID>,
        created: (Date) async throws -> [LinearIssue], byIds: ([LinearIssue.ID]) async throws -> [LinearIssue]
    ) async throws -> [LinearIssue] {
        let fresh = lastPoll == .distantPast ? [] : try await created(lastPoll)
        let rest = waiting.subtracting(fresh.map(\.id))
        guard !rest.isEmpty else { return fresh }
        return try await fresh + byIds(rest.sorted())
    }

    /// Pauses GitHub work when `error` is a rate limit, and says whether it was.
    private func pausedForRateLimit(_ error: Error, repoPath: String) async -> Bool {
        guard GitHubRateLimit.isRateLimit(error) else { return false }
        await daemon.pauseGitHub(until: GitHubRateLimit.resetDate(repoPath: repoPath))
        return true
    }

    /// Links and completes started issues that no run or merge watch follows,
    /// such as work done by hand or by agents from before a state reset. Their
    /// worktrees are left alone, since they may hold work of your own.
    private func sweepStartedIssues(client: LinearClient, listing: PullRequestListing) async {
        let issues: [LinearIssueStatus]
        let pullRequests: [PullRequest]
        do {
            issues = try await client.fetchStartedIssues(teamIds: workspace.teamIds)
            guard !issues.isEmpty else { return }
            pullRequests = try await listing.allPullRequests()
        } catch {
            if await pausedForRateLimit(error, repoPath: listing.repoPath) { return }
            await logOnce("Could not check started issues' pull requests: \(error)")
            return
        }

        let tracked = await daemon.trackedIssueIds(workspace: workspace.name)
        await requeueStoppedAtUsageLimit(issues: issues, pullRequests: pullRequests, tracked: tracked, repoPath: listing.repoPath)
        for item in StartedIssueSweep.plan(issues: issues, pullRequests: pullRequests, excluding: tracked) {
            await link(item.pullRequests, issueId: item.issue.id, identifier: item.issue.identifier, client: client)
            guard let merged = item.merged else { continue }
            do {
                if try await client.completeIssue(id: item.issue.id) {
                    log("Marked \(item.issue.identifier) done in Linear; its pull request merged: \(merged.url)")
                    await daemon.recordActivity(
                        ActivityEvent(time: Date(), kind: .issueCompleted, identifier: item.issue.identifier, detail: merged.url),
                        workspace: workspace.name)
                }
                await daemon.forgetLinkedPullRequests(issueId: item.issue.id, workspace: workspace.name)
            } catch {
                await logOnce("Could not mark \(item.issue.identifier) done in Linear: \(error)")
            }
        }
    }

    /// Queues again the started issues whose agents the Claude usage limit
    /// stopped before the daemon could pause them, each in its worktree's
    /// latest Claude session when it has one.
    private func requeueStoppedAtUsageLimit(
        issues: [LinearIssueStatus], pullRequests: [PullRequest], tracked: Set<String>, repoPath: String
    ) async {
        let runner = AgentRunner()
        let now = Date()
        let stopped = StartedIssueSweep.stoppedAtUsageLimit(
            issues: issues, pullRequests: pullRequests,
            processed: await daemon.processedIssueIds(workspace: workspace.name), tracked: tracked
        ) { runner.usageLimitHit(identifier: $0, now: now) != nil }
        for issue in stopped {
            guard await daemon.claimUsageLimitRecovery(
                issueId: issue.id, logModified: runner.agentLogModified(identifier: issue.identifier))
            else { continue }
            let session = FollowUpFile.worktree(branch: issue.branchName, repoPath: repoPath)
                .flatMap(runner.latestClaudeSession(inWorktree:))
            await daemon.requeueStoppedAtUsageLimit(issue, sessionId: session, workspace: workspace)
        }
    }

    /// Logs a problem the first time it happens, rather than every poll.
    private func logOnce(_ message: String) async {
        if await daemon.firstReport("[\(workspace.name)] \(message)") {
            log(message + " (logged once)")
        }
    }

    /// Links the pull requests of agents still running, which open them well
    /// before they end, as they go on to watch CI.
    private func linkRunningAgentsPullRequests(client: LinearClient, listing: PullRequestListing) async {
        let runs = await daemon.launchedRuns(workspace: workspace.name)
        guard !runs.isEmpty else { return }
        let all: [PullRequest]
        do {
            all = try await listing.allPullRequests()
        } catch {
            // Retried next poll; the merge watch logs other failures.
            _ = await pausedForRateLimit(error, repoPath: listing.repoPath)
            return
        }
        for run in runs {
            // Most running agents have no pull request yet.
            let pullRequests = all.filter { $0.headRefName == run.branchName }
            await link(pullRequests, issueId: run.issueId, identifier: run.identifier, client: client)
        }
    }

    /// Attaches each pull request not yet linked to the issue in Linear.
    private func link(_ pullRequests: [PullRequest], issueId: String, identifier: LinearIssue.Identifier, client: LinearClient) async {
        let linked = await daemon.linkedPullRequests(issueId: issueId, workspace: workspace.name)
        for pullRequest in pullRequests where !linked.contains(pullRequest.url) {
            do {
                try await client.linkURL(
                    issueId: issueId, url: pullRequest.url, title: "Pull request #\(pullRequest.number)"
                )
                await daemon.recordLinkedPullRequest(pullRequest.url, issueId: issueId, workspace: workspace.name)
                log("Linked \(pullRequest.url) to \(identifier) in Linear")
            } catch {
                // Linear refuses to attach a URL the issue already has, as one
                // linked before the daemon kept records, or by hand.
                if let attached = try? await client.attachmentURLs(issueId: issueId), attached.contains(pullRequest.url) {
                    await daemon.recordLinkedPullRequest(pullRequest.url, issueId: issueId, workspace: workspace.name)
                    continue
                }
                // Not recorded, so the next poll tries again.
                await logOnce("Could not link \(pullRequest.url) to \(identifier) in Linear: \(error)")
            }
        }
    }

    /// Looks up the pull request of each issue whose agent has ended. A merged
    /// one completes the issue in Linear and removes its worktree; a closed
    /// one, or none at all, ends the watch. An open one with new reviews from
    /// the signed-in GitHub user gets an agent to address them; failing that,
    /// one that conflicts with its base branch gets an agent to merge it in.
    private func checkPullRequests(client: LinearClient, listing: PullRequestListing) async {
        let checker = PullRequestChecker()
        let repoPath = listing.repoPath
        for pending in await daemon.pendingMerges(workspace: workspace.name) {
            let pullRequests: [PullRequest]
            do {
                pullRequests = try await listing.pullRequests(branch: pending.branchName)
            } catch {
                if await pausedForRateLimit(error, repoPath: repoPath) { return }
                // The listing is shared, so every other watch would fail the same way.
                log("Could not list pull requests to check \(pending.identifier) and the other watches: \(error)")
                return
            }
            // Before the merge check, which may end the watch.
            await link(pullRequests, issueId: pending.issueId, identifier: pending.identifier, client: client)
            let status = MergeStatus.of(pullRequests)

            switch status {
            case .open:
                // A stacked pull request first follows the one below it. One
                // that was just restacked, or handed to a conflict agent, is
                // not checked for conflicts this poll: GitHub's state is of
                // before the push.
                var pending = pending
                if pending.stack != nil, let pullRequest = pullRequests.first(where: { $0.state == .open }) {
                    switch await keepStacked(&pending, pullRequest: pullRequest, listing: listing) {
                    case .unchanged: break
                    case .pushed, .conflicted: continue
                    }
                }
                // One agent at a time on a branch: conflicts wait for the
                // review agent to end.
                // A conflict run waits too when the reviews could not be checked,
                // as the watch after it would count them as addressed.
                guard await checkReviews(of: pending, pullRequests: pullRequests, repoPath: repoPath) == .none
                else { continue }
                await checkConflicts(of: pending, pullRequests: pullRequests, listing: listing)
                continue
            case .merged(let pr):
                log("\(pending.identifier) merged in \(pr.url)")
                do {
                    if try await client.completeIssue(id: pending.issueId) {
                        log("  Marked \(pending.identifier) done in Linear")
                        await daemon.recordActivity(
                            ActivityEvent(time: Date(), kind: .issueCompleted, identifier: pending.identifier, detail: pr.url),
                            workspace: workspace.name)
                    }
                } catch {
                    // Leave it pending so the next poll tries again.
                    log("  Could not mark \(pending.identifier) done in Linear: \(error)")
                    continue
                }
                await proposeAddedTodos(of: pr, pending: pending, client: client, repoPath: repoPath)
                let workLog = AgentRunner().workLog(identifier: pending.identifier)
                do {
                    try await checker.finishWorktree(branch: pending.branchName, repoPath: repoPath, logFile: workLog)
                    log("  Removed the worktree for \(pending.branchName)")
                } catch {
                    log("  Could not remove the worktree for \(pending.branchName): \(error)")
                }
            case .closed(let pr):
                log("\(pending.identifier)'s pull request was closed without merging: \(pr.url)")
            case .missing:
                log("\(pending.identifier)'s agent ended without opening a pull request")
            }
            await daemon.stopAwaitingMerge(issueId: pending.issueId, workspace: workspace.name)
        }
    }

    private enum StackOutcome {
        /// Nothing was pushed to the branch.
        case unchanged
        /// The base was merged in and pushed.
        case pushed
        /// The base conflicts; a conflict agent is queued.
        case conflicted
    }

    /// Keeps a stacked pull request current with the one below it: merges
    /// the lower branch in when it moved, follows the lower pull request's
    /// merge to the next base, and makes the upper pull request a draft
    /// when the lower one was closed without a merge. Never rebases.
    private func keepStacked(
        _ pending: inout PendingMerge, pullRequest: PullRequest, listing: PullRequestListing
    ) async -> StackOutcome {
        guard let stack = pending.stack else { return .unchanged }
        let repoPath = listing.repoPath
        let lower: [PullRequest]
        do {
            lower = try await listing.pullRequests(branch: stack.branch.rawValue)
        } catch {
            _ = await pausedForRateLimit(error, repoPath: repoPath)
            return .unchanged
        }
        let defaultBranch = GitBranch.Name(rawValue: Git.defaultBranch(in: repoPath) ?? "main")
        let lowerHead = await listing.remoteHead(of: stack.branch.rawValue).map { GitCommit.SHA(rawValue: $0) }
        let action = Stacking.action(
            for: stack, pullRequest: pullRequest, lower: lower, lowerHead: lowerHead, defaultBranch: defaultBranch)
        let checker = listing.checker
        switch action {
        case .none:
            return .unchanged
        case .restack:
            log("\(stack.identifier)'s branch \(stack.branch) moved; merging it into \(pending.identifier)'s \(pullRequest.url)")
            return await mergeBase(stack.branch, into: &pending, stack: stack, pullRequest: pullRequest, listing: listing)
        case .lowerMerged(let base, let retarget):
            log("\(stack.identifier)'s pull request merged; \(pending.identifier)'s \(pullRequest.url) now targets \(base)")
            if retarget {
                do {
                    try await checker.retarget(number: pullRequest.number, base: base.rawValue, repoPath: repoPath)
                } catch {
                    if await pausedForRateLimit(error, repoPath: repoPath) { return .unchanged }
                    await logOnce("Could not retarget \(pullRequest.url) to \(base): \(error)")
                    return .unchanged
                }
            }
            // The next pull request down, or none on the default branch.
            var next: StackBase?
            if base != defaultBranch, let below = await daemon.pendingMerge(branch: base.rawValue, workspace: workspace.name),
               let lowerPullRequest = try? await listing.pullRequests(branch: base.rawValue).first(where: { $0.state == .open }) {
                next = StackBase(
                    identifier: below.identifier, branch: base, number: lowerPullRequest.number, url: lowerPullRequest.url,
                    depth: below.stackDepth, baseHead: nil, drafted: stack.drafted)
            }
            if stack.drafted == true, next?.drafted != true {
                await setDraft(false, of: pullRequest, identifier: pending.identifier, repoPath: repoPath)
            }
            return await mergeBase(base, into: &pending, stack: next, pullRequest: pullRequest, listing: listing)
        case .lowerClosed:
            log("\(stack.identifier)'s pull request \(stack.url) was closed without a merge; "
                + "\(pending.identifier)'s \(pullRequest.url) becomes a draft for you to decide on")
            guard await setDraft(true, of: pullRequest, identifier: pending.identifier, repoPath: repoPath) else { return .unchanged }
            var updated = stack
            updated.drafted = true
            pending.stack = updated
            await daemon.updateStack(updated, issueId: pending.issueId, workspace: workspace.name)
            await daemon.recordActivity(
                ActivityEvent(time: Date(), kind: .stackBaseClosed, identifier: pending.identifier, detail: pullRequest.url),
                workspace: workspace.name)
            return .unchanged
        case .lowerReopened:
            log("\(stack.identifier)'s pull request \(stack.url) is open again; \(pending.identifier)'s \(pullRequest.url) leaves draft")
            guard await setDraft(false, of: pullRequest, identifier: pending.identifier, repoPath: repoPath) else { return .unchanged }
            var updated = stack
            updated.drafted = nil
            pending.stack = updated
            await daemon.updateStack(updated, issueId: pending.issueId, workspace: workspace.name)
            return .unchanged
        }
    }

    @discardableResult
    private func setDraft(_ draft: Bool, of pullRequest: PullRequest, identifier: LinearIssue.Identifier, repoPath: String) async -> Bool {
        do {
            try await PullRequestChecker().setDraft(draft, number: pullRequest.number, repoPath: repoPath)
            return true
        } catch {
            if await pausedForRateLimit(error, repoPath: repoPath) { return false }
            await logOnce("Could not \(draft ? "make \(pullRequest.url) a draft" : "mark \(pullRequest.url) ready for review"): \(error)")
            return false
        }
    }

    /// Merges `origin/<base>` into the issue's branch in its worktree, with a
    /// merge commit, and pushes. Records `stack` as what the pull request is
    /// on afterwards, with the base's head once merged in. A conflict goes
    /// to a conflict agent, as with any base.
    private func mergeBase(
        _ base: GitBranch.Name, into pending: inout PendingMerge, stack: StackBase?, pullRequest: PullRequest, listing: PullRequestListing
    ) async -> StackOutcome {
        let repoPath = listing.repoPath
        guard let worktree = FollowUpFile.worktree(branch: pending.branchName, repoPath: repoPath) else {
            await logOnce("Could not merge \(base) into \(pending.identifier)'s branch: its worktree is gone")
            return .unchanged
        }
        let outcome: Stacking.MergeOutcome
        do {
            outcome = try Stacking.mergeBase(base, into: pending.branchName, worktree: worktree)
        } catch {
            await logOnce("Could not merge \(base) into \(pending.identifier)'s branch: \(error)")
            return .unchanged
        }
        func record(_ stack: StackBase?, baseHead: GitCommit.SHA?) async {
            var stack = stack
            stack?.baseHead = baseHead
            pending.stack = stack
            await daemon.updateStack(stack, issueId: pending.issueId, workspace: workspace.name)
        }
        switch outcome {
        case .merged(let head, let baseHead):
            log("  Merged \(base) into \(pending.branchName) and pushed \(head.short)")
            await listing.forgetRemoteHead(of: pending.branchName)
            await record(stack, baseHead: baseHead)
            await daemon.recordActivity(
                ActivityEvent(time: Date(), kind: .restacked, identifier: pending.identifier, detail: "\(base) into \(pullRequest.url)"),
                workspace: workspace.name)
            return .pushed
        case .upToDate(let baseHead):
            await record(stack, baseHead: baseHead)
            return .unchanged
        case .conflicted:
            guard let head = pullRequest.headRefOid, let baseHead = await listing.remoteHead(of: base.rawValue) else { return .unchanged }
            let attempt = ConflictAttempt(head: head, base: baseHead)
            // The watch after the agent keeps following the same base, which
            // the agent merges in; the base's head is taken as merged, so
            // that one that keeps conflicting is not retried each poll.
            await record(stack, baseHead: GitCommit.SHA(rawValue: baseHead))
            guard attempt != pending.conflictAttempt else {
                await logOnce("\(pending.identifier)'s branch still conflicts with \(base) after an agent tried; "
                    + "waiting for either branch to move: \(pullRequest.url)")
                return .conflicted
            }
            log("  \(base) conflicts with \(pending.branchName); queuing an agent to resolve it")
            await daemon.enqueueConflictResolution(
                of: pending, pullRequest: pullRequest, baseBranch: base.rawValue, attempt: attempt, workspace: workspace)
            return .conflicted
        }
    }

    /// Queues an agent for the open pull request when `gh`'s own user has
    /// reviewed it since the issue's last agent started.
    private func checkReviews(of pending: PendingMerge, pullRequests: [PullRequest], repoPath: String) async -> ReviewCheck {
        guard let pullRequest = pullRequests.first(where: { $0.state == .open }) else { return .none }
        // A watch from before reviews were followed counts from the pull
        // request's head commit. Looked up once, before looking at reviews, so
        // its baseline is the head the pull request has now.
        var lastCommit: Date?
        if pending.reviewsHandledThrough == nil, let sha = pullRequest.headRefOid {
            do {
                lastCommit = try await PullRequestChecker().commitDate(sha: sha, repoPath: repoPath)
            } catch {
                if await pausedForRateLimit(error, repoPath: repoPath) { return .failed }
                // Rather than the present, which would pass over its reviews.
                log("Could not find when \(pending.identifier)'s head commit was made, retrying next poll: \(error)")
                return .failed
            }
        }
        let handledThrough = await daemon.reviewsHandledThrough(
            pending, lastCommit: lastCommit, workspace: workspace.name)
        guard let reviews = pullRequest.reviews, !reviews.isEmpty else { return .none }
        let login: String
        do {
            login = try await daemon.viewerLogin(repoPath: repoPath)
        } catch {
            if await pausedForRateLimit(error, repoPath: repoPath) { return .failed }
            await logOnce("Could not find the GitHub user whose reviews to address: \(error)")
            return .failed
        }
        // A daemon from before the Claude pause took the reviews of an agent
        // that the usage limit stopped as addressed. One more agent reads them.
        let runner = AgentRunner()
        let logModified = runner.agentLogModified(identifier: pending.identifier)
        if runner.usageLimitHit(identifier: pending.identifier, now: Date()) != nil,
           PullRequestReview.stoppedAtUsageLimit(reviews, by: login, logWrittenAt: logModified),
           await daemon.claimUsageLimitRecovery(issueId: pending.issueId, logModified: logModified) {
            log("\(pending.identifier)'s last agent stopped at the Claude usage limit; queuing its reviews on \(pullRequest.url) again")
            await daemon.enqueueReview(of: pending, pullRequest: pullRequest, workspace: workspace)
            return .queued
        }
        let unaddressed = PullRequestReview.unaddressed(reviews, by: login, after: handledThrough)
        guard !unaddressed.isEmpty else { return .none }
        log("\(pending.identifier) has \(unaddressed.count) new review(s) from \(login) on \(pullRequest.url)")
        await daemon.enqueueReview(of: pending, pullRequest: pullRequest, workspace: workspace)
        return .queued
    }

    /// Queues an agent to merge the base branch into the open pull request's
    /// branch when GitHub finds they conflict, unless the issue's last agent
    /// already tried with the same heads.
    private func checkConflicts(of pending: PendingMerge, pullRequests: [PullRequest], listing: PullRequestListing) async {
        guard let pullRequest = pullRequests.first(where: { $0.state == .open }), pullRequest.conflicts,
              let head = pullRequest.headRefOid, let base = pullRequest.baseRefName
        else { return }
        // GitHub's base commit for the pull request is the one at its last
        // push, so the base branch's head comes from git.
        guard let baseHead = await listing.remoteHead(of: base) else {
            await logOnce("Could not fetch \(base) to check \(pending.identifier)'s conflicts with it")
            return
        }
        let attempt = ConflictAttempt(head: head, base: baseHead)
        guard attempt != pending.conflictAttempt else {
            await logOnce(
                "\(pending.identifier)'s pull request still conflicts with \(base) after an agent tried to resolve it; "
                    + "waiting for either branch to move: \(pullRequest.url)")
            return
        }
        log("\(pending.identifier)'s pull request conflicts with \(base): \(pullRequest.url)")
        await daemon.enqueueConflictResolution(
            of: pending, pullRequest: pullRequest, baseBranch: base, attempt: attempt, workspace: workspace)
    }

    private enum ReviewCheck {
        /// An agent is queued to address new reviews.
        case queued
        /// No review needs an agent.
        case none
        /// The reviews could not be checked; tried again next poll.
        case failed
    }

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] [\(workspace.name)] \(message)")
    }
}
