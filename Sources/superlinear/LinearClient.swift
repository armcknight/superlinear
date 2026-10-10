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

    func fetchNewIssues(since: Date, teamIds: [String]) async throws -> [LinearIssue] {
        var allIssues: [LinearIssue] = []
        var cursor: String? = nil

        let formatter = ISO8601DateFormatter()
        let afterValue = formatter.string(from: since)

        repeat {
            var variables: [String: Any] = [
                "after": ["gt": afterValue]
            ]
            if !teamIds.isEmpty {
                variables["teamIds"] = teamIds
            }
            if let cursor {
                variables["cursor"] = cursor
            }

            let query = teamIds.isEmpty ? Self.queryAllTeams : Self.queryWithTeams
            let result = try await execute(query, variables: variables, as: IssuesData.self).issues
            allIssues.append(contentsOf: result.nodes)

            if result.pageInfo.hasNextPage {
                cursor = result.pageInfo.endCursor
            } else {
                cursor = nil
            }
        } while cursor != nil

        return allIssues
    }

    private static let issueStateQuery = """
    query IssueState($id: String!) {
      issue(id: $id) {
        state { type }
        team {
          states(filter: { type: { eq: "completed" } }) {
            nodes { id position }
          }
        }
      }
    }
    """

    private static let updateStateMutation = """
    mutation CompleteIssue($id: String!, $stateId: String!) {
      issueUpdate(id: $id, input: { stateId: $stateId }) { success }
    }
    """

    /// Moves the issue to its team's first completed state. Returns false,
    /// changing nothing, when the issue is already completed or canceled, as
    /// Linear's GitHub integration may have done on the merge.
    func completeIssue(id: String) async throws -> Bool {
        let issue = try await execute(Self.issueStateQuery, variables: ["id": id], as: IssueStateData.self).issue
        guard !["completed", "canceled"].contains(issue.state.type) else { return false }
        guard let done = issue.team.states.nodes.min(by: { $0.position < $1.position }) else {
            throw LinearClientError.apiError(["The issue's team has no completed state"])
        }
        let result = try await execute(
            Self.updateStateMutation, variables: ["id": id, "stateId": done.id], as: IssueUpdateData.self
        )
        guard result.issueUpdate.success else { throw LinearClientError.invalidResponse }
        return true
    }

    private struct IssuesData: Decodable {
        let issues: IssuesResponse
    }

    private struct IssuesResponse: Decodable {
        let nodes: [LinearIssue]
        let pageInfo: PageInfo

        struct PageInfo: Decodable {
            let hasNextPage: Bool
            let endCursor: String?
        }
    }

    private struct IssueStateData: Decodable {
        let issue: Issue

        struct Issue: Decodable {
            let state: WorkflowState
            let team: Team
        }

        struct WorkflowState: Decodable {
            let type: String
        }

        struct Team: Decodable {
            let states: States
        }

        struct States: Decodable {
            let nodes: [Node]
        }

        struct Node: Decodable {
            let id: String
            let position: Double
        }
    }

    private struct IssueUpdateData: Decodable {
        let issueUpdate: Result

        struct Result: Decodable {
            let success: Bool
        }
    }

    private struct GraphQLResponse<T: Decodable>: Decodable {
        let data: T?
        let errors: [GraphQLError]?
    }

    private struct GraphQLError: Decodable {
        let message: String
    }

    private func execute<T: Decodable>(_ query: String, variables: [String: Any], as type: T.Type) async throws -> T {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")

        let body: [String: Any] = ["query": query, "variables": variables]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)

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
