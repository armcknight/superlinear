import Foundation

/// A decision the owner entered at a standup for an issue that needs a human.
struct StandupDecision: Codable, Sendable, Equatable {
    var time: Date
    var identifier: LinearIssue.Identifier
    var text: String
}

/// What standups decided for one workspace.
struct WorkspaceStandup: Codable, Sendable, Equatable {
    /// When the owner last finished a standup.
    var lastStandupAt: Date?
    /// When a standup first showed each proposal, by proposal ID.
    var proposalsShownAt: [Proposal.ID: Date] = [:]
    /// The proposals standups decided, as they ended up: applied, rejected,
    /// or pending still with the error that kept one from applying.
    var proposalOutcomes: [Proposal] = []
    /// The decisions entered for issues that need a human.
    var decisions: [StandupDecision] = []
    /// Issues no agent starts on until a standup releases them: identifiers
    /// by issue ID.
    var held: [LinearIssue.ID: LinearIssue.Identifier] = [:]
    /// Issue IDs in the order agents are to start them, ahead of the rest.
    var order: [LinearIssue.ID] = []
    /// The identifiers of the issues the last standup unblocked.
    var unblocked: [LinearIssue.Identifier] = []

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastStandupAt = try container.decodeIfPresent(Date.self, forKey: .lastStandupAt)
        proposalsShownAt = try container.decodeIfPresent([Proposal.ID: Date].self, forKey: .proposalsShownAt) ?? [:]
        proposalOutcomes = try container.decodeIfPresent([Proposal].self, forKey: .proposalOutcomes) ?? []
        decisions = try container.decodeIfPresent([StandupDecision].self, forKey: .decisions) ?? []
        held = try container.decodeIfPresent([LinearIssue.ID: LinearIssue.Identifier].self, forKey: .held) ?? [:]
        order = try container.decodeIfPresent([LinearIssue.ID].self, forKey: .order) ?? []
        unblocked = try container.decodeIfPresent([LinearIssue.Identifier].self, forKey: .unblocked) ?? []
    }

    /// How long proposal outcomes and shown times stay, once the daemon has
    /// long since taken them in.
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    /// Drops outcomes and shown times older than `retention`.
    mutating func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        proposalOutcomes.removeAll { ($0.decidedAt ?? now) < cutoff }
        proposalsShownAt = proposalsShownAt.filter { $0.value >= cutoff }
    }

    /// Where `issueId` comes in `order`, or nil when it was not moved.
    func rank(of issueId: LinearIssue.ID) -> Int? {
        order.firstIndex(of: issueId)
    }

    /// `items` sorted by `order`, the ones in it first, the rest keeping their order.
    func ordered<T>(_ items: [T], id: (T) -> LinearIssue.ID) -> [T] {
        let ranked = items.enumerated().map { (rank(of: id($0.element)) ?? order.count + $0.offset, $0.element) }
        return ranked.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

/// The file the standup writes: what standups decided, per workspace. It is
/// apart from the state file, which the daemon rewrites from memory at each
/// change; the daemon reads this one at each poll and takes it in.
struct StandupRecord: Codable, Sendable, Equatable {
    var workspaces: [String: WorkspaceStandup] = [:]

    static func fileURL(home: String = Paths.home) -> URL {
        URL(fileURLWithPath: "\(home)/.local/share/superlinear/standup.json")
    }

    static func load(from url: URL = fileURL()) -> StandupRecord {
        guard let data = try? Data(contentsOf: url) else { return StandupRecord() }
        do {
            return try decoded(from: data)
        } catch {
            print("[superlinear] Could not read \(url.path), starting with no standups: \(error)")
            return StandupRecord()
        }
    }

    func save(to url: URL = fileURL()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmpURL = url.appendingPathExtension("tmp")
        try encoded().write(to: tmpURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decoded(from data: Data) throws -> StandupRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StandupRecord.self, from: data)
    }

    subscript(workspace: String) -> WorkspaceStandup {
        get { workspaces[workspace] ?? WorkspaceStandup() }
        set { workspaces[workspace] = newValue }
    }
}
