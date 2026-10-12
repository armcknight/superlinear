import Foundation

struct WorkspaceConfig: Codable, Sendable {
    let name: String
    let apiKey: String
    let repoPath: String
    let teamIds: [String]
    let pollIntervalSeconds: Int
    /// Whether to work on the repository's GitHub issues too: those you open,
    /// and those you comment `/superlinear-do` on.
    let githubIssues: Bool

    enum CodingKeys: String, CodingKey {
        case name, apiKey, repoPath, teamIds, pollIntervalSeconds, githubIssues
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        repoPath = try container.decode(String.self, forKey: .repoPath)
        teamIds = try container.decodeIfPresent([String].self, forKey: .teamIds) ?? []
        pollIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 60
        githubIssues = try container.decodeIfPresent(Bool.self, forKey: .githubIssues) ?? false
    }
}

struct Config: Codable, Sendable {
    static let defaultMaxConcurrentAgents = 3

    let workspaces: [WorkspaceConfig]
    /// Agents allowed to run at once, across all workspaces. Further issues
    /// wait in a queue and start, oldest first, as running agents finish.
    let maxConcurrentAgents: Int

    enum CodingKeys: String, CodingKey {
        case workspaces, maxConcurrentAgents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaces = try container.decode([WorkspaceConfig].self, forKey: .workspaces)
        let max = try container.decodeIfPresent(Int.self, forKey: .maxConcurrentAgents)
            ?? Self.defaultMaxConcurrentAgents
        maxConcurrentAgents = Swift.max(1, max)
    }

    static var defaultPath: String { "\(Paths.home)/.config/superlinear/config.json" }

    static func load(from path: String? = nil) throws -> Config {
        let data = try Data(contentsOf: URL(fileURLWithPath: path ?? defaultPath))
        return try decoded(from: data)
    }

    static func decoded(from data: Data) throws -> Config {
        try JSONDecoder().decode(Config.self, from: data)
    }
}
