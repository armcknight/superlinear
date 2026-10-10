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

        await checkPullRequests(client: client)
    }

    /// Looks up the pull request of each issue whose agent has ended. A merged
    /// one completes the issue in Linear and removes its worktree; a closed
    /// one, or none at all, ends the watch.
    private func checkPullRequests(client: LinearClient) async {
        let checker = PullRequestChecker()
        let repoPath = NSString(string: workspace.repoPath).expandingTildeInPath
        for pending in await daemon.pendingMerges(workspace: workspace.name) {
            let status: MergeStatus
            do {
                status = MergeStatus.of(try await checker.pullRequests(branch: pending.branchName, repoPath: repoPath))
            } catch {
                log("Could not check the pull request for \(pending.identifier): \(error)")
                continue
            }

            switch status {
            case .open:
                continue
            case .merged(let pr):
                log("\(pending.identifier) merged in \(pr.url)")
                do {
                    if try await client.completeIssue(id: pending.issueId) {
                        log("  Marked \(pending.identifier) done in Linear")
                    }
                } catch {
                    // Leave it pending so the next poll tries again.
                    log("  Could not mark \(pending.identifier) done in Linear: \(error)")
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

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] [\(workspace.name)] \(message)")
    }
}
