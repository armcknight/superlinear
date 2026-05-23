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
            let result = try await executeQuery(query, variables: variables)
            allIssues.append(contentsOf: result.nodes)

            if result.pageInfo.hasNextPage {
                cursor = result.pageInfo.endCursor
            } else {
                cursor = nil
            }
        } while cursor != nil

        return allIssues
    }

    private struct IssuesResponse: Decodable {
        let nodes: [LinearIssue]
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

    private func executeQuery(_ query: String, variables: [String: Any]) async throws -> IssuesResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")

        let body: [String: Any] = ["query": query, "variables": variables]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let response = try decoder.decode(GraphQLResponse<IssuesResponse>.self, from: data)

        if let errors = response.errors, !errors.isEmpty {
            throw LinearClientError.apiError(errors.map(\.message))
        }

        guard let issues = response.data?.issues else {
            throw LinearClientError.invalidResponse
        }

        return issues
    }
}
