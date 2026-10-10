import Foundation

struct LinearIssue: Codable, Sendable {
    let id: String
    let identifier: String
    let title: String
    let branchName: String
    let createdAt: Date
    let team: Team

    struct Team: Codable, Sendable {
        let id: String
        let key: String
    }
}

/// An issue the daemon has already processed, as `superlinear status` reports
/// it: where it stands in Linear, and the branch its pull request comes from.
struct LinearIssueStatus: Codable, Sendable, Equatable {
    let id: String
    let identifier: String
    let title: String
    let branchName: String
    let state: State

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

    // Query filtering by team IDs (non-empty teamIds)
    private static let queryWithTeams = """
    query NewIssues($after: DateComparator, $teamIds: [ID!], $cursor: String) {
      issues(
        filter: {
          createdAt: $after
          team: { id: { in: $teamIds } }
          state: { type: { in: ["backlog", "unstarted"] } }
        }
        orderBy: createdAt
        first: 50
        after: $cursor
      ) {
        nodes {
          id
          identifier
          title
          branchName
          createdAt
          team { id key }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
    """

    // Query without team filter
    private static let queryAllTeams = """
    query NewIssues($after: DateComparator, $cursor: String) {
      issues(
        filter: {
          createdAt: $after
          state: { type: { in: ["backlog", "unstarted"] } }
        }
        orderBy: createdAt
        first: 50
        after: $cursor
      ) {
        nodes {
          id
          identifier
          title
          branchName
          createdAt
          team { id key }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
    """

    // Archived issues are left out, as they are by default, so issues long
    // since finished drop out of the status report on their own.
    private static let queryByIds = """
    query IssuesById($ids: [ID!], $cursor: String) {
      issues(
        filter: { id: { in: $ids } }
        first: 50
        after: $cursor
      ) {
        nodes {
          id
          identifier
          title
          branchName
          state { name type }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
    """

    func fetchNewIssues(since: Date, teamIds: [String]) async throws -> [LinearIssue] {
        let formatter = ISO8601DateFormatter()
        var variables: [String: Any] = [
            "after": ["gt": formatter.string(from: since)]
        ]
        if !teamIds.isEmpty {
            variables["teamIds"] = teamIds
        }
        let query = teamIds.isEmpty ? Self.queryAllTeams : Self.queryWithTeams
        return try await fetchAll(query, variables: variables)
    }

    /// The issues with these IDs, 50 IDs to a request so no request grows
    /// with the number of issues processed.
    func fetchIssues(ids: [String]) async throws -> [LinearIssueStatus] {
        var issues: [LinearIssueStatus] = []
        for start in stride(from: 0, to: ids.count, by: 50) {
            let batch = Array(ids[start..<min(start + 50, ids.count)])
            issues += try await fetchAll(Self.queryByIds, variables: ["ids": batch])
        }
        return issues
    }

    /// Runs an `issues` query, following its pages to the end.
    private func fetchAll<Node: Decodable>(_ query: String, variables: [String: Any]) async throws -> [Node] {
        var allNodes: [Node] = []
        var cursor: String? = nil

        repeat {
            var pageVariables = variables
            if let cursor {
                pageVariables["cursor"] = cursor
            }

            let result: IssuesResponse<Node> = try await executeQuery(query, variables: pageVariables)
            allNodes.append(contentsOf: result.nodes)

            if result.pageInfo.hasNextPage {
                cursor = result.pageInfo.endCursor
            } else {
                cursor = nil
            }
        } while cursor != nil

        return allNodes
    }

    private struct IssuesResponse<Node: Decodable>: Decodable {
        let nodes: [Node]
        let pageInfo: PageInfo

        struct PageInfo: Decodable {
            let hasNextPage: Bool
            let endCursor: String?
        }
    }

    private struct GraphQLResponse<T: Decodable>: Decodable {
        let data: DataWrapper?
        let errors: [GraphQLError]?

        struct DataWrapper: Decodable {
            let issues: T
        }
    }

    private struct GraphQLError: Decodable {
        let message: String
    }

    private func executeQuery<Node: Decodable>(
        _ query: String, variables: [String: Any]
    ) async throws -> IssuesResponse<Node> {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")

        let body: [String: Any] = ["query": query, "variables": variables]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let response = try decoder.decode(GraphQLResponse<IssuesResponse<Node>>.self, from: data)

        if let errors = response.errors, !errors.isEmpty {
            throw LinearClientError.apiError(errors.map(\.message))
        }

        guard let issues = response.data?.issues else {
            throw LinearClientError.invalidResponse
        }

        return issues
    }
}
