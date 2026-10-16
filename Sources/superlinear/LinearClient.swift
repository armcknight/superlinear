import Foundation
import Tagged

/// The type of a Linear workflow state. Every state a team defines has one.
enum LinearStateType: String, Codable, Sendable, CaseIterable {
    case triage, backlog, unstarted, started, completed, canceled
}

/// An issue an agent may start on. The fields after `team` decide whether
/// one does, and in what order; each is absent when the query did not ask.
struct LinearIssue: Codable, Sendable, Equatable {
    typealias ID = Tagged<LinearIssue, String>

    let id: ID
    let identifier: String
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
            let identifier: String
            let state: Kind

            struct Kind: Codable, Sendable, Equatable {
                let type: String
            }
        }
    }

    var labelNames: [String] { labels?.nodes.map(\.name) ?? [] }

    /// The identifiers of the issues blocking this one that are neither
    /// completed nor canceled.
    var openBlockers: [String] {
        (inverseRelations?.nodes ?? [])
            .filter { $0.type == "blocks" && !["completed", "canceled"].contains($0.issue.state.type) }
            .map(\.issue.identifier)
    }
}

/// Tags for the IDs of Linear objects superlinear has no type for, so that
/// one kind of ID cannot go where another must.
enum LinearTeam { typealias ID = Tagged<LinearTeam, String> }
enum LinearProject { typealias ID = Tagged<LinearProject, String> }
enum LinearDocument { typealias ID = Tagged<LinearDocument, String> }
enum LinearLabel { typealias ID = Tagged<LinearLabel, String> }

/// An issue the daemon has already processed, as `superlinear status` reports
/// it: where it stands in Linear, and the branch its pull request comes from.
struct LinearIssueStatus: Codable, Sendable, Equatable {
    let id: String
    let identifier: String
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
    var isClosed: Bool { isCompleted || state.type == "canceled" }
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
            return try await fetchAll(.readyIssues, variables: ["states": states])
        }
        return try await fetchAll(.readyIssuesInTeams, variables: ["states": states, "teamIds": teamIds])
    }

    /// The issues with these IDs, with what it takes to decide whether an
    /// agent starts on them, 25 IDs to a request. Archived issues are absent.
    func fetchCandidates(ids: [LinearIssue.ID]) async throws -> [LinearIssue] {
        var issues: [LinearIssue] = []
        for start in stride(from: 0, to: ids.count, by: 25) {
            let batch = ids[start..<min(start + 25, ids.count)].map(\.rawValue)
            issues += try await fetchAll(.candidatesById, variables: ["ids": batch])
        }
        return issues
    }

    /// The issues with these identifiers, such as SPL-5, in one request.
    /// Linear filters by number and team key separately, so the result can
    /// hold other pairings of the two; only exact identifiers are kept.
    /// Identifiers Linear does not have are simply absent.
    func fetchIssues(identifiers: [String]) async throws -> [LinearIssueStatus] {
        let pairs = identifiers.compactMap { identifier -> (String, Int)? in
            guard let dash = identifier.lastIndex(of: "-"), let number = Int(identifier[identifier.index(after: dash)...])
            else { return nil }
            return (String(identifier[..<dash]), number)
        }
        guard !pairs.isEmpty else { return [] }
        let issues: [LinearIssueStatus] = try await fetchAll(
            .issuesByNumber,
            variables: ["numbers": Array(Set(pairs.map(\.1))), "keys": Array(Set(pairs.map(\.0)))]
        )
        let wanted = Set(identifiers)
        return issues.filter { wanted.contains($0.identifier) }
    }

    /// Issues in a started state, such as In Progress or In Review, optionally
    /// filtered by team.
    func fetchStartedIssues(teamIds: [String]) async throws -> [LinearIssueStatus] {
        if teamIds.isEmpty {
            return try await fetchAll(.startedIssues, variables: [:])
        }
        return try await fetchAll(.startedIssuesInTeams, variables: ["teamIds": teamIds])
    }

    func fetchNewIssues(since: Date, teamIds: [String]) async throws -> [LinearIssue] {
        let formatter = ISO8601DateFormatter()
        var variables: [String: Any] = [
            "after": ["gt": formatter.string(from: since)]
        ]
        if !teamIds.isEmpty {
            variables["teamIds"] = teamIds
        }
        return try await fetchAll(teamIds.isEmpty ? .newIssues : .newIssuesInTeams, variables: variables)
    }

    /// The issues with these IDs, 50 IDs to a request so no request grows
    /// with the number of issues processed.
    func fetchIssues(ids: [String]) async throws -> [LinearIssueStatus] {
        var issues: [LinearIssueStatus] = []
        for start in stride(from: 0, to: ids.count, by: 50) {
            let batch = Array(ids[start..<min(start + 50, ids.count)])
            issues += try await fetchAll(.issuesById, variables: ["ids": batch])
        }
        return issues
    }

    /// Runs an `issues` query, following its pages to the end.
    private func fetchAll<Node: Decodable>(_ query: LinearQuery, variables: [String: Any]) async throws -> [Node] {
        var allNodes: [Node] = []
        var cursor: String? = nil

        repeat {
            var pageVariables = variables
            if let cursor {
                pageVariables["cursor"] = cursor
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
        try await move(id: id, toFirst: "completed", unlessIn: ["completed", "canceled"]) != nil
    }

    /// Moves the issue to its team's first started state, such as In
    /// Progress. Returns false, changing nothing, when the issue is already
    /// started, completed or canceled.
    func startIssue(id: String) async throws -> Bool {
        try await move(id: id, toFirst: "started", unlessIn: ["started", "completed", "canceled"]) != nil
    }

    /// Moves the issue to its team's first state of type `type`, unless its
    /// state type is one of `skipped`, and returns Linear's whole answer, or
    /// nil when it changed nothing.
    func move(id: String, toFirst type: String, unlessIn skipped: Set<String> = []) async throws -> JSONValue? {
        let issue = try await execute(
            .issueState, variables: ["id": id, "type": type], as: LinearQuery.IssueStateData.self
        ).issue
        guard !skipped.contains(issue.state.type) else { return nil }
        guard let target = issue.team.states.nodes.min(by: { $0.position < $1.position }) else {
            throw LinearClientError.apiError(["The issue's team has no \(type) state"])
        }
        return try await mutate(.moveIssue, variables: ["id": id, "stateId": target.id], field: "issueUpdate")
    }

    /// Attaches `url` to the issue. Linear keeps one attachment per URL on an
    /// issue, so linking a URL twice changes nothing.
    func linkURL(issueId: String, url: String, title: String) async throws {
        try await mutate(
            .linkURL, variables: ["issueId": issueId, "url": url, "title": title], field: "attachmentLinkURL"
        )
    }

    /// The URLs attached to the issue.
    func attachmentURLs(issueId: String) async throws -> Set<String> {
        let data = try await execute(.attachments, variables: ["id": issueId], as: LinearQuery.AttachmentsData.self)
        return Set(data.issue.attachments.nodes.map(\.url))
    }

    private struct GraphQLResponse<T: Decodable>: Decodable {
        let data: T?
        let errors: [GraphQLError]?
    }

    private struct GraphQLError: Decodable {
        let message: String
    }

    func execute<T: Decodable>(_ query: LinearQuery, variables: [String: Any], as type: T.Type) async throws -> T {
        try await send(query, variables: variables).decoded(as: T.self)
    }

    /// Runs a mutation whose result `field` reports `success`, failing when it
    /// does not, and returns the whole of Linear's answer, for the audit log.
    @discardableResult
    func mutate(_ query: LinearQuery, variables: [String: Any], field: String) async throws -> JSONValue {
        let response = try await send(query, variables: variables)
        let results = try response.decoded(as: [String: LinearQuery.Success].self)
        guard results[field]?.success == true else { throw LinearClientError.invalidResponse }
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

    private func send(_ query: LinearQuery, variables: [String: Any]) async throws -> Response {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")

        let body: [String: Any] = ["query": query.text, "variables": variables]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        return Response(data: data)
    }
}
