import Foundation

/// Which issues a workspace starts agents for.
enum IssueSelection: String, Codable, Sendable {
    /// Issues created since the last poll, in the backlog or unstarted.
    case new
    /// Every open issue in one of the workspace's `readyStates`, whenever
    /// it was created, most important first.
    case ready
}

struct WorkspaceConfig: Codable, Sendable {
    static let defaultReadyStates: [LinearStateType] = [.unstarted]
    static let defaultHumanLabels = ["Needs human", "Spike"]

    let name: String
    let apiKey: String
    let repoPath: String
    let teamIds: [String]
    let pollIntervalSeconds: Int
    let selection: IssueSelection
    /// Linear state types that mean "build this" in `ready` mode.
    let readyStates: [LinearStateType]
    /// Labels that keep an issue for a person: no agent starts on it. Teams
    /// name their own labels, so these are names, matched in any case.
    let humanLabels: [String]
    /// Whether to work on the repository's GitHub issues too: those you open,
    /// and those you comment `/superlinear-do` on.
    let githubIssues: Bool

    enum CodingKeys: String, CodingKey {
        case name, apiKey, repoPath, teamIds, pollIntervalSeconds, selection, readyStates, humanLabels, githubIssues
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        repoPath = try container.decode(String.self, forKey: .repoPath)
        teamIds = try container.decodeIfPresent([String].self, forKey: .teamIds) ?? []
        pollIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 60
        selection = try container.decodeIfPresent(IssueSelection.self, forKey: .selection) ?? .new
        readyStates = try container.decodeIfPresent([LinearStateType].self, forKey: .readyStates) ?? Self.defaultReadyStates
        humanLabels = try container.decodeIfPresent([String].self, forKey: .humanLabels) ?? Self.defaultHumanLabels
        githubIssues = try container.decodeIfPresent(Bool.self, forKey: .githubIssues) ?? false
    }

    /// The Linear state types an issue may be in for an agent to start on it.
    var startableStates: Set<LinearStateType> {
        switch selection {
        case .new: [.backlog, .unstarted]
        case .ready: Set(readyStates)
        }
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
