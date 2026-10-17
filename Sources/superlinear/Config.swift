import Foundation

/// Which issues a workspace starts agents for.
enum IssueSelection: String, Codable, Sendable {
    /// Issues created since the last poll, in the backlog or unstarted.
    case new
    /// Every open issue in one of the workspace's `readyStates`, whenever
    /// it was created, most important first.
    case ready
}

struct WorkspaceConfig: Decodable, Sendable {
    static let defaultReadyStates: [LinearStateType] = [.unstarted]
    static let defaultHumanLabels = ["Needs human", "Spike"]
    static let defaultProposalExpiryDays = 7

    let name: String
    let apiKey: String
    let repoPath: String
    let teamIds: [String]
    /// `teamIds` as Linear's API takes them.
    var watchedTeams: [LinearTeam.ID] { teamIds.map { LinearTeam.ID(rawValue: $0) } }
    let pollIntervalSeconds: Int
    let selection: IssueSelection
    /// Linear state types that mean "build this" in `ready` mode.
    let readyStates: [LinearStateType]
    /// Labels that keep an issue for a person: no agent starts on it. Teams
    /// name their own labels, so these are names, matched in any case.
    let humanLabels: [String]
    /// The trust level of each kind of proposal.
    let autonomy: Autonomy
    /// Days after which a pending proposal expires, counted from when it was
    /// put in Linear.
    let proposalExpiryDays: Int
    /// Planning settings.
    let planning: PlanningConfig

    enum CodingKeys: String, CodingKey {
        case name, apiKey, repoPath, teamIds, pollIntervalSeconds, selection, readyStates, humanLabels
        case autonomy, proposalExpiryDays, planning
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
        // A misspelt kind would otherwise leave its default in force unseen.
        var overrides: [ProposalKind: TrustLevel] = [:]
        for (key, level) in try container.decodeIfPresent([String: TrustLevel].self, forKey: .autonomy) ?? [:] {
            guard let kind = ProposalKind(rawValue: key) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .autonomy, in: container,
                    debugDescription: "Unknown proposal kind \"\(key)\". Known kinds: "
                        + ProposalKind.allCases.map(\.rawValue).joined(separator: ", ")
                )
            }
            overrides[kind] = level
        }
        autonomy = Autonomy(overrides: overrides)
        let expiry = try container.decodeIfPresent(Int.self, forKey: .proposalExpiryDays) ?? Self.defaultProposalExpiryDays
        proposalExpiryDays = max(1, expiry)
        planning = try container.decodeIfPresent(PlanningConfig.self, forKey: .planning) ?? PlanningConfig()
    }

    /// The Linear state types an issue may be in for an agent to start on it.
    var startableStates: Set<LinearStateType> {
        switch selection {
        case .new: [.backlog, .unstarted]
        case .ready: Set(readyStates)
        }
    }
}

/// A workspace's `planning` settings.
struct PlanningConfig: Decodable, Sendable, Equatable {
    /// Whether the planning job runs.
    var enabled = false
    /// The Linear document holding the project's spec, which the planning
    /// job reads and may propose changes to.
    var specDocumentURL: String?

    init(enabled: Bool = false, specDocumentURL: String? = nil) {
        self.enabled = enabled
        self.specDocumentURL = specDocumentURL
    }

    enum CodingKeys: String, CodingKey {
        case enabled, specDocumentURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        specDocumentURL = try container.decodeIfPresent(String.self, forKey: .specDocumentURL)
    }

    /// The document's ID as Linear's API takes it: the slug at the end of its
    /// URL, as in `https://linear.app/team/document/spec-0123abcd`.
    var specDocumentId: LinearDocument.ID? {
        guard let url = specDocumentURL.flatMap(URL.init(string:)) else { return nil }
        let last = url.lastPathComponent
        guard let slug = last.split(separator: "-").last, !slug.isEmpty, last != "/" else { return nil }
        return LinearDocument.ID(rawValue: String(slug))
    }
}

struct Config: Decodable, Sendable {
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
