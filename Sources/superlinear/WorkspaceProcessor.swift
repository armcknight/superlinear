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
        for issue in newIssues {
            do {
                let makeInitFailed = try await processor.process(issue: issue)
                await daemon.markProcessed(issue.id, workspace: workspace.name, makeInitFailed: makeInitFailed)
            } catch {
                log("Error processing issue \(issue.identifier): \(error)")
            }
        }

        await daemon.updateLastPoll(pollTime, workspace: workspace.name)
    }

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] [\(workspace.name)] \(message)")
    }
}
