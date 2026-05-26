import Foundation

actor Daemon {
    private var state: State
    private let config: Config

    init(config: Config) {
        self.config = config
        self.state = State.load()
    }

    func run() async throws {
        print("[superlinear] Starting with \(config.workspaces.count) workspace(s)")

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
                let timestamp = ISO8601DateFormatter().string(from: Date())
                print("[\(timestamp)] [\(workspace.name)] Poll error: \(error)")
            }
            do {
                try await Task.sleep(for: .seconds(workspace.pollIntervalSeconds))
            } catch {
                break // Task cancelled
            }
        }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] [\(workspace.name)] Workspace loop stopped")
    }

    // MARK: - State accessors (called from WorkspaceProcessor on actor context)

    func lastPollTimestamp(workspace: String) -> Date {
        state.lastPollTimestamp(workspace: workspace)
    }

    func filterUnprocessed(_ issues: [LinearIssue], workspace: String) -> [LinearIssue] {
        issues.filter { !state.isProcessed($0.id, workspace: workspace) }
    }

    func markProcessed(_ issueId: String, workspace: String) {
        state.markProcessed(issueId, workspace: workspace)
        try? state.save()
    }

    func updateLastPoll(_ date: Date, workspace: String) {
        state.updateLastPoll(date, workspace: workspace)
        try? state.save()
    }
}
