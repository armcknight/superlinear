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

        let processor = IssueProcessor(workspace: workspace)
        await withTaskGroup(of: Void.self) { group in
            for issue in newIssues {
                group.addTask {
                    do {
                        let makeInitFailed = try await processor.process(issue: issue)
                        await self.daemon.markProcessed(issue.id, workspace: self.workspace.name, makeInitFailed: makeInitFailed)
                    } catch {
                        self.log("Error processing issue \(issue.identifier): \(error)")
                    }
                }
            }
        }

        await daemon.updateLastPoll(pollTime, workspace: workspace.name)
    }

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] [\(workspace.name)] \(message)")
    }
}
