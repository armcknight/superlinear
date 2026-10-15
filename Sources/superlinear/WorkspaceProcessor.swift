import Foundation

struct WorkspaceProcessor: Sendable {
    let workspace: WorkspaceConfig
    let daemon: Daemon

    func poll() async throws {
        let lastPoll = await daemon.lastPollTimestamp(workspace: workspace.name)
        let client = LinearClient(apiKey: workspace.apiKey)

        log("Polling since \(ISO8601DateFormatter().string(from: lastPoll))")

        let issues = try await client.fetchNewIssues(since: lastPoll, teamIds: workspace.teamIds)
        let pollTime = Date()

        let newIssues = await daemon.filterUnprocessed(issues, workspace: workspace.name)

        if newIssues.isEmpty {
            log("No new issues")
        } else {
            log("Found \(newIssues.count) new issue(s)")
        }

        for issue in newIssues {
            await daemon.enqueueAgent(for: issue, workspace: workspace)
        }

        await daemon.updateLastPoll(pollTime, workspace: workspace.name)

        if workspace.githubIssues {
            await pollGitHubIssues()
        }

        let listing = PullRequestListing(repoPath: NSString(string: workspace.repoPath).expandingTildeInPath)
        await linkRunningAgentsPullRequests(client: client, listing: listing)
        await checkPullRequests(client: client, listing: listing)
        await sweepStartedIssues(client: client, listing: listing)
    }

    /// Queues the repository's open GitHub issues that you opened since GitHub
    /// polling began, or that you commented `/superlinear-do` on. A failure is
    /// logged and leaves Linear's work to go on.
    private func pollGitHubIssues() async {
        let repoPath = NSString(string: workspace.repoPath).expandingTildeInPath
        let client = GitHubIssueClient()
        let since = await daemon.gitHubIssuesSince(workspace: workspace.name)
        let requested: [GitHubIssue]
        do {
            let login = try await daemon.viewerLogin(repoPath: repoPath)
            requested = try await client.openIssues(repoPath: repoPath).filter {
                $0.isRequested(by: login, openedSince: since)
            }
        } catch {
            await logOnce("Could not list GitHub issues: \(error)")
            return
        }
        let newIssues = await daemon.filterUnprocessed(requested, workspace: workspace.name)
        if !newIssues.isEmpty {
            log("Found \(newIssues.count) new GitHub issue(s)")
        }
        // Oldest first, as Linear's are.
        for issue in newIssues.sorted(by: { $0.number < $1.number }) {
            await daemon.enqueueAgent(for: issue, workspace: workspace)
        }
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
            await logOnce("Could not check started issues' pull requests: \(error)")
            return
        }

        let tracked = await daemon.trackedIssueIds(workspace: workspace.name)
        for item in StartedIssueSweep.plan(issues: issues, pullRequests: pullRequests, excluding: tracked) {
            await link(item.pullRequests, issueId: item.issue.id, identifier: item.issue.identifier, client: client)
            guard let merged = item.merged else { continue }
            do {
                if try await client.completeIssue(id: item.issue.id) {
                    log("Marked \(item.issue.identifier) done in Linear; its pull request merged: \(merged.url)")
                }
                await daemon.forgetLinkedPullRequests(issueId: item.issue.id, workspace: workspace.name)
            } catch {
                await logOnce("Could not mark \(item.issue.identifier) done in Linear: \(error)")
            }
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
        // GitHub links a pull request to the issue it closes by itself.
        for run in await daemon.launchedRuns(workspace: workspace.name) where run.gitHubIssue == nil {
            // Most running agents have no pull request yet; a failed lookup is
            // retried next poll, and logged when the agent ends.
            guard let pullRequests = try? await listing.allPullRequests().filter({ $0.headRefName == run.branchName })
            else { continue }
            await link(pullRequests, issueId: run.issueId, identifier: run.identifier, client: client)
        }
    }

    /// Attaches each pull request not yet linked to the issue in Linear.
    private func link(_ pullRequests: [PullRequest], issueId: String, identifier: String, client: LinearClient) async {
        let linked = await daemon.linkedPullRequests(issueId: issueId, workspace: workspace.name)
        for pullRequest in pullRequests where !linked.contains(pullRequest.url) {
            do {
                try await client.linkURL(
                    issueId: issueId, url: pullRequest.url, title: "Pull request #\(pullRequest.number)"
                )
                await daemon.recordLinkedPullRequest(pullRequest.url, issueId: issueId, workspace: workspace.name)
                log("Linked \(pullRequest.url) to \(identifier) in Linear")
            } catch {
                // Not recorded, so the next poll tries again.
                await logOnce("Could not link \(pullRequest.url) to \(identifier) in Linear: \(error)")
            }
        }
    }

    /// Looks up the pull request of each issue whose agent has ended. A merged
    /// one completes the issue in Linear and removes its worktree; a closed
    /// one, or none at all, ends the watch. An open one with new reviews from
    /// the signed-in GitHub user gets an agent to address them.
    private func checkPullRequests(client: LinearClient, listing: PullRequestListing) async {
        let checker = PullRequestChecker()
        let repoPath = listing.repoPath
        for pending in await daemon.pendingMerges(workspace: workspace.name) {
            let pullRequests: [PullRequest]
            do {
                pullRequests = try await listing.pullRequests(branch: pending.branchName)
            } catch {
                log("Could not check the pull request for \(pending.identifier): \(error)")
                continue
            }
            // Before the merge check, which may end the watch.
            if pending.gitHubIssue == nil {
                await link(pullRequests, issueId: pending.issueId, identifier: pending.identifier, client: client)
            }
            let status = MergeStatus.of(pullRequests)

            switch status {
            case .open:
                await checkReviews(of: pending, pullRequests: pullRequests, repoPath: repoPath)
                continue
            case .merged(let pr):
                log("\(pending.identifier) merged in \(pr.url)")
                do {
                    if let number = pending.gitHubIssue {
                        if try await GitHubIssueClient().completeIssue(number: number, repoPath: repoPath) {
                            log("  Closed GitHub issue #\(number)")
                        }
                    } else if try await client.completeIssue(id: pending.issueId) {
                        log("  Marked \(pending.identifier) done in Linear")
                    }
                } catch {
                    // Leave it pending so the next poll tries again.
                    log("  Could not mark \(pending.identifier) done: \(error)")
                    continue
                }
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

    /// Queues an agent for the open pull request when `gh`'s own user has
    /// reviewed it since the issue's last agent started.
    private func checkReviews(of pending: PendingMerge, pullRequests: [PullRequest], repoPath: String) async {
        guard let pullRequest = pullRequests.first(where: { $0.state == .open }) else { return }
        // A watch from before reviews were followed counts from the pull
        // request's head commit. Looked up once, before looking at reviews, so
        // its baseline is the head the pull request has now.
        var lastCommit: Date?
        if pending.reviewsHandledThrough == nil, let sha = pullRequest.headRefOid {
            do {
                lastCommit = try await PullRequestChecker().commitDate(sha: sha, repoPath: repoPath)
            } catch {
                // Rather than the present, which would pass over its reviews.
                log("Could not find when \(pending.identifier)'s head commit was made, retrying next poll: \(error)")
                return
            }
        }
        let handledThrough = await daemon.reviewsHandledThrough(
            pending, lastCommit: lastCommit, workspace: workspace.name)
        guard let reviews = pullRequest.reviews, !reviews.isEmpty else { return }
        let login: String
        do {
            login = try await daemon.viewerLogin(repoPath: repoPath)
        } catch {
            await logOnce("Could not find the GitHub user whose reviews to address: \(error)")
            return
        }
        let unaddressed = PullRequestReview.unaddressed(reviews, by: login, after: handledThrough)
        guard !unaddressed.isEmpty else { return }
        log("\(pending.identifier) has \(unaddressed.count) new review(s) from \(login) on \(pullRequest.url)")
        await daemon.enqueueReview(of: pending, pullRequest: pullRequest, workspace: workspace)
    }

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] [\(workspace.name)] \(message)")
    }
}
