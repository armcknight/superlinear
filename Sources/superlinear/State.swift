import Foundation

struct WorkspaceState: Codable, Sendable {
    var processedIssueIds: Set<String>
    var lastPollTimestamp: Date

    init() {
        processedIssueIds = []
        lastPollTimestamp = .distantPast
    }
}

struct State: Codable, Sendable {
    var workspaces: [String: WorkspaceState]

    init() {
        workspaces = [:]
    }

    static func load() -> State {
        let url = stateFileURL()
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(State.self, from: data) else {
            return State()
        }
        return state
    }

    func save() throws {
        let url = Self.stateFileURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        let tmpURL = url.appendingPathExtension("tmp")
        try data.write(to: tmpURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
    }

    mutating func markProcessed(_ issueId: String, workspace: String) {
        workspaces[workspace, default: WorkspaceState()].processedIssueIds.insert(issueId)
    }

    mutating func updateLastPoll(_ date: Date, workspace: String) {
        workspaces[workspace, default: WorkspaceState()].lastPollTimestamp = date
    }

    func isProcessed(_ issueId: String, workspace: String) -> Bool {
        workspaces[workspace]?.processedIssueIds.contains(issueId) ?? false
    }

    func lastPollTimestamp(workspace: String) -> Date {
        workspaces[workspace]?.lastPollTimestamp ?? .distantPast
    }

    private static func stateFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/superlinear/state.json")
    }
}
