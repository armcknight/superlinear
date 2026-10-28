import Foundation
import Tagged

/// The type of a Linear workflow state. Every state a team defines has one.
/// A type Linear adds later decodes as `unknown`, so it does not fail the
/// query that reads it.
enum LinearStateType: String, Codable, Sendable, CaseIterable {
    case triage, backlog, unstarted, started, completed, canceled, duplicate, unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LinearStateType(rawValue: raw) ?? .unknown
    }

    /// The types of states an issue is done in, whether it was done, given
    /// up or found to repeat another.
    static let closed: [LinearStateType] = [.completed, .canceled, .duplicate]
}

/// An issue an agent may start on. The fields after `team` decide whether
/// one does, and in what order; each is absent when the query did not ask.
struct LinearIssue: Codable, Sendable, Equatable {
    typealias ID = Tagged<LinearIssue, String>
    /// The key a person reads, such as SPL-5, as opposed to the `ID`.
    typealias Identifier = Tagged<IdentifierTag, String>
    enum IdentifierTag {}

    let id: ID
    let identifier: Identifier
    let title: String
    let branchName: String
    let createdAt: Date
    let team: Team
    var state: LinearIssueStatus.State? = nil
    /// 0 for no priority, then 1 (urgent) to 4 (low).
    var priority: Double? = nil
    var sortOrder: Double? = nil
    var project: Ranked? = nil
    var projectMilestone: Ranked? = nil
    var labels: Labels? = nil
    /// Relations in which another issue is the subject, such as one that
    /// blocks this one.
    var inverseRelations: Relations? = nil

    struct Team: Codable, Sendable, Equatable {
        let id: String
        let key: String
    }

    struct Ranked: Codable, Sendable, Equatable {
        let sortOrder: Double
    }

    struct Labels: Codable, Sendable, Equatable {
        let nodes: [Label]

        struct Label: Codable, Sendable, Equatable {
            let name: String
        }
    }

    struct Relations: Codable, Sendable, Equatable {
        let nodes: [Relation]

        struct Relation: Codable, Sendable, Equatable {
            /// `blocks`, `duplicate`, `related` or `similar`.
            let type: String
            let issue: Related
        }

        struct Related: Codable, Sendable, Equatable {
            let id: LinearIssue.ID
            let identifier: LinearIssue.Identifier
            let state: Kind

            struct Kind: Codable, Sendable, Equatable {
                let type: String
            }
        }
    }

    var labelNames: [String] { labels?.nodes.map(\.name) ?? [] }

    /// The identifiers of the issues blocking this one that are neither
    /// completed nor canceled.
    var openBlockers: [LinearIssue.Identifier] {
        (inverseRelations?.nodes ?? [])
            .filter { $0.type == "blocks" && !LinearStateType.closed.map(\.rawValue).contains($0.issue.state.type) }
            .map(\.issue.identifier)
    }
}

extension Tagged where Tag == LinearIssue.IdentifierTag, RawValue == String {
    /// Whether it sorts before `other` as a person would: SPL-9 before SPL-10.
    func sortsBefore(_ other: Self) -> Bool {
        rawValue.localizedStandardCompare(other.rawValue) == .orderedAscending
    }
}

/// Tags for the IDs and names of Linear objects superlinear has no type for,
/// so that one kind of ID cannot go where another must, nor a name where an
/// ID must.
enum LinearTeam {
    typealias ID = Tagged<LinearTeam, String>
    /// The key a person reads at the start of an identifier, as `SPL`.
    typealias Key = Tagged<KeyTag, String>
    enum KeyTag {}
}
enum LinearProject {
    typealias ID = Tagged<LinearProject, String>
    typealias Name = Tagged<NameTag, String>
    enum NameTag {}
}
enum LinearMilestone {
    typealias Name = Tagged<LinearMilestone, String>
}
enum LinearDocument { typealias ID = Tagged<LinearDocument, String> }
enum LinearState {
    typealias ID = Tagged<LinearState, String>
    /// The name a person reads, as `In Progress`.
    typealias Name = Tagged<NameTag, String>
    enum NameTag {}
}
enum LinearComment { typealias ID = Tagged<LinearComment, String> }
enum LinearUser { typealias ID = Tagged<LinearUser, String> }
enum LinearLabel {
    typealias ID = Tagged<LinearLabel, String>
    typealias Name = Tagged<NameTag, String>
    enum NameTag {}
}

extension LinearIssue {
    /// Linear's priority: 0 for none, then 1 (urgent) to 4 (low), as the API
    /// answers it, a number.
    typealias Priority = Tagged<PriorityTag, Double>
    enum PriorityTag {}
}

/// The types of relation between two issues, as Linear's `IssueRelationType`.
/// `blocks` and `duplicate` go one way: the issue blocks, or is the duplicate
/// of, the related one. The others go both ways.
enum LinearRelationType: String, Codable, Sendable, CaseIterable {
    case blocks, duplicate, related, similar

    var isDirected: Bool { self == .blocks || self == .duplicate }
}

/// A commit, for the tag on its SHA.
enum GitCommit {
    typealias SHA = Tagged<GitCommit, String>
}

extension Tagged where Tag == GitCommit, RawValue == String {
    /// The first 7 characters, as git shows a SHA.
    var short: String { String(rawValue.prefix(7)) }
}

/// A git branch, for the tag on its name.
enum GitBranch {
    typealias Name = Tagged<GitBranch, String>
}

/// A Claude Code session, for the tag on its ID. Lowercase, as Claude names
/// its transcripts.
enum ClaudeSession {
    typealias ID = Tagged<ClaudeSession, String>
}

/// An issue the daemon has already processed, as `superlinear status` reports
/// it: where it stands in Linear, and the branch its pull request comes from.
struct LinearIssueStatus: Codable, Sendable, Equatable {
    let id: String
    let identifier: LinearIssue.Identifier
    let title: String
    let branchName: String
    let state: State
    /// When the issue last moved into a started state, when the query asked.
    var startedAt: Date? = nil

    struct State: Codable, Sendable, Equatable {
        let name: String
        /// One of Linear's workflow state types: `triage`, `backlog`,
        /// `unstarted`, `started`, `completed` or `canceled`.
        let type: String
    }

    var isCompleted: Bool { state.type == "completed" }
    var isClosed: Bool { LinearStateType.closed.map(\.rawValue).contains(state.type) }
}

enum LinearClientError: Error {
    case invalidResponse
    case apiError([String])
}

struct LinearClient: Sendable {
    let apiKey: String
    private let endpoint = URL(string: "https://api.linear.app/graphql")!

    /// Open issues whose state type is one of `states`, whenever created,
    /// optionally filtered by team.
    func fetchReadyIssues(states: [LinearStateType], teamIds: [String]) async throws -> [LinearIssue] {
        let states = states.map(\.rawValue)
        if teamIds.isEmpty {
            return try await fetchAll(.readyIssues, variables: [.states: states])
        }
        return try await fetchAll(.readyIssuesInTeams, variables: [.states: states, .teamIds: teamIds])
    }

    /// The issues with these IDs, with what it takes to decide whether an
    /// agent starts on them, 25 IDs to a request. Archived issues are absent.
    func fetchCandidates(ids: [LinearIssue.ID]) async throws -> [LinearIssue] {
        var issues: [LinearIssue] = []
        for start in stride(from: 0, to: ids.count, by: 25) {
            let batch = ids[start..<min(start + 25, ids.count)].map(\.rawValue)
            issues += try await fetchAll(.candidatesById, variables: [.ids: batch])
        }
        return issues
    }

    /// The issues with these identifiers, such as SPL-5, in one request.
    /// Linear filters by number and team key separately, so the result can
    /// hold other pairings of the two; only exact identifiers are kept.
    /// Identifiers Linear does not have are simply absent.
    func fetchIssues(identifiers: [LinearIssue.Identifier]) async throws -> [LinearIssueStatus] {
        guard let variables = Self.numberVariables(identifiers) else { return [] }
        let issues: [LinearIssueStatus] = try await fetchAll(.issuesByNumber, variables: variables)
        let wanted = Set(identifiers)
        return issues.filter { wanted.contains($0.identifier) }
    }

    /// The issues with these identifiers, with their text, labels and
    /// relations.
    func namedIssues(identifiers: [LinearIssue.Identifier]) async throws -> [PlanningIssue] {
        guard let variables = Self.numberVariables(identifiers) else { return [] }
        let nodes: [LinearQuery.PlanningIssueNode] = try await fetchAll(.namedIssues, variables: variables)
        let wanted = Set(identifiers)
        return nodes.map(\.planningIssue).filter { wanted.contains($0.identifier) }
    }

    /// The numbers and team keys of the identifiers, as the queries by
    /// number take them, or nil when there are none.
    private static func numberVariables(_ identifiers: [LinearIssue.Identifier]) -> [LinearVariable: Any]? {
        let pairs = identifiers.map(\.rawValue).compactMap { identifier -> (String, Int)? in
            guard let dash = identifier.lastIndex(of: "-"), let number = Int(identifier[identifier.index(after: dash)...])
            else { return nil }
            return (String(identifier[..<dash]), number)
        }
        guard !pairs.isEmpty else { return nil }
        return [.numbers: Array(Set(pairs.map(\.1))), .keys: Array(Set(pairs.map(\.0)))]
    }

    /// Issues in a started state, such as In Progress or In Review, optionally
    /// filtered by team.
    func fetchStartedIssues(teamIds: [String]) async throws -> [LinearIssueStatus] {
        if teamIds.isEmpty {
            return try await fetchAll(.startedIssues, variables: [:])
        }
        return try await fetchAll(.startedIssuesInTeams, variables: [.teamIds: teamIds])
    }

    func fetchNewIssues(since: Date, teamIds: [String]) async throws -> [LinearIssue] {
        let formatter = ISO8601DateFormatter()
        var variables: [LinearVariable: Any] = [
            .after: [LinearVariable.gt: formatter.string(from: since)]
        ]
        if !teamIds.isEmpty {
            variables[.teamIds] = teamIds
        }
        return try await fetchAll(teamIds.isEmpty ? .newIssues : .newIssuesInTeams, variables: variables)
    }

    /// The issues with these IDs, 50 IDs to a request so no request grows
    /// with the number of issues processed.
    func fetchIssues(ids: [String]) async throws -> [LinearIssueStatus] {
        var issues: [LinearIssueStatus] = []
        for start in stride(from: 0, to: ids.count, by: 50) {
            let batch = Array(ids[start..<min(start + 50, ids.count)])
            issues += try await fetchAll(.issuesById, variables: [.ids: batch])
        }
        return issues
    }

    /// Runs an `issues` query, following its pages to the end.
    func fetchAll<Node: Decodable>(_ query: LinearQuery, variables: [LinearVariable: Any]) async throws -> [Node] {
        var allNodes: [Node] = []
        var cursor: String? = nil

        repeat {
            var pageVariables = variables
            if let cursor {
                pageVariables[.cursor] = cursor
            }

            let result = try await execute(query, variables: pageVariables, as: LinearQuery.IssuesData<Node>.self).issues
            allNodes.append(contentsOf: result.nodes)

            if result.pageInfo.hasNextPage {
                cursor = result.pageInfo.endCursor
            } else {
                cursor = nil
            }
        } while cursor != nil

        return allNodes
    }

    /// Moves the issue to its team's first completed state. Returns false,
    /// changing nothing, when the issue is already completed or canceled, as
    /// Linear's GitHub integration may have done on the merge.
    func completeIssue(id: String) async throws -> Bool {
        try await move(id: id, toFirst: "completed", unlessIn: ["completed", "canceled", "duplicate"]) != nil
    }

    /// Moves the issue to its team's first started state, such as In
    /// Progress. Returns false, changing nothing, when the issue is already
    /// started, completed or canceled.
    func startIssue(id: String) async throws -> Bool {
        try await move(id: id, toFirst: "started", unlessIn: ["started", "completed", "canceled", "duplicate"]) != nil
    }

    /// Moves the issue to its team's first state of type `type`, unless its
    /// state type is one of `skipped`, and returns Linear's whole answer, or
    /// nil when it changed nothing.
    func move(id: String, toFirst type: String, unlessIn skipped: Set<String> = []) async throws -> JSONValue? {
        let issue = try await execute(
            .issueState, variables: [.id: id, .type: type], as: LinearQuery.IssueStateData.self
        ).issue
        guard !skipped.contains(issue.state.type) else { return nil }
        guard let target = issue.team.states.nodes.min(by: { $0.position < $1.position }) else {
            throw LinearClientError.apiError(["The issue's team has no \(type) state"])
        }
        return try await mutate(.moveIssue, variables: [.id: id, .stateId: target.id], field: .issueUpdate)
    }

    /// Attaches `url` to the issue. Linear keeps one attachment per URL on an
    /// issue, so linking a URL twice changes nothing.
    func linkURL(issueId: String, url: String, title: String) async throws {
        try await mutate(
            .linkURL, variables: [.issueId: issueId, .url: url, .title: title], field: .attachmentLinkURL
        )
    }

    /// The URLs attached to the issue.
    func attachmentURLs(issueId: String) async throws -> Set<String> {
        let data = try await execute(.attachments, variables: [.id: issueId], as: LinearQuery.AttachmentsData.self)
        return Set(data.issue.attachments.nodes.map(\.url))
    }

    private struct GraphQLResponse<T: Decodable>: Decodable {
        let data: T?
        let errors: [GraphQLError]?
    }

    private struct GraphQLError: Decodable {
        let message: String
    }

    /// The team for proposals that belong to no issue: the workspace's first
    /// configured team, or else the first Linear lists.
    func proposalTeamId(teamIds: [String]) async throws -> LinearTeam.ID {
        if let first = teamIds.first { return LinearTeam.ID(rawValue: first) }
        let teams = try await execute(.firstTeam, variables: [:], as: LinearQuery.TeamsData.self).teams.nodes
        guard let team = teams.first else { throw LinearClientError.invalidResponse }
        return team.id
    }

    func execute<T: Decodable>(_ query: LinearQuery, variables: [LinearVariable: Any], as type: T.Type) async throws -> T {
        try await send(query, variables: variables).decoded(as: T.self)
    }

    /// Runs a mutation whose result `field` reports `success`, failing when it
    /// does not, and returns the whole of Linear's answer, for the audit log.
    @discardableResult
    func mutate(_ query: LinearQuery, variables: [LinearVariable: Any], field: LinearField) async throws -> JSONValue {
        let response = try await send(query, variables: variables)
        let results = try response.decoded(as: [String: LinearQuery.Success].self)
        guard results[field.rawValue]?.success == true else { throw LinearClientError.invalidResponse }
        return try response.decoded(as: JSONValue.self)
    }

    private struct Response {
        let data: Data

        func decoded<T: Decodable>(as type: T.Type) throws -> T {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let response = try decoder.decode(GraphQLResponse<T>.self, from: data)

            if let errors = response.errors, !errors.isEmpty {
                throw LinearClientError.apiError(errors.map(\.message))
            }

            guard let result = response.data else {
                throw LinearClientError.invalidResponse
            }

            return result
        }
    }

    private func send(_ query: LinearQuery, variables: [LinearVariable: Any]) async throws -> Response {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")

        let body: [String: Any] = ["query": query.text, "variables": Self.encoded(variables)]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        return Response(data: data)
    }

    /// The variables as JSON takes them, with each name, also in the inputs
    /// and filters nested in them, spelled out.
    static func encoded(_ value: Any) -> Any {
        if let variables = value as? [LinearVariable: Any] {
            return Dictionary(uniqueKeysWithValues: variables.map { ($0.key.rawValue, encoded($0.value)) })
        }
        if let values = value as? [Any] { return values.map(encoded) }
        return value
    }
}
