import Foundation

/// GitHub's rate limits, shared by the daemon, its agents and
/// `superlinear status`: 5,000 GraphQL points and 5,000 REST requests an
/// hour, and secondary limits on bursts. While one is used up, every `gh`
/// call fails, so the daemon skips its GitHub work until the reset rather
/// than failing at every step of every poll.
enum GitHubRateLimit {
    /// Whether `error` is GitHub refusing a call for a rate limit.
    static func isRateLimit(_ error: Error) -> Bool {
        "\(error)".localizedCaseInsensitiveContains("rate limit")
    }

    /// How long to wait when GitHub does not say, as for a secondary limit.
    static let fallbackDelay: TimeInterval = 5 * 60

    /// When GitHub lifts the limit: the latest reset among the budgets used
    /// up, or `fallbackDelay` from `now` when none is, or GitHub cannot be
    /// asked. GraphQL's own `rateLimit` is asked, as the REST `rate_limit`
    /// endpoint has been seen to report GraphQL points left while none were.
    static func resetDate(repoPath: String, now: Date = Date()) -> Date {
        var resets: [Date] = []
        if let data = try? GitHubCLI.run(
            ["api", "graphql", "-f", "query={ rateLimit { remaining resetAt } }"], in: repoPath),
            let reset = graphQLReset(data)
        {
            resets.append(reset)
        }
        if let data = try? GitHubCLI.run(["api", "rate_limit"], in: repoPath), let reset = restReset(data) {
            resets.append(reset)
        }
        return resets.filter { $0 > now }.max() ?? now.addingTimeInterval(fallbackDelay)
    }

    /// The GraphQL reset, if no points remain.
    static func graphQLReset(_ data: Data) -> Date? {
        struct Response: Decodable {
            struct Body: Decodable {
                struct Limit: Decodable {
                    let remaining: Int
                    let resetAt: Date
                }
                let rateLimit: Limit
            }
            let data: Body
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let limit = try? decoder.decode(Response.self, from: data).data.rateLimit, limit.remaining == 0
        else { return nil }
        return limit.resetAt
    }

    /// The REST reset, if no requests remain.
    static func restReset(_ data: Data) -> Date? {
        struct Response: Decodable {
            struct Resources: Decodable {
                struct Limit: Decodable {
                    let remaining: Int
                    let reset: TimeInterval
                }
                let core: Limit
            }
            let resources: Resources
        }
        guard let core = try? JSONDecoder().decode(Response.self, from: data).resources.core, core.remaining == 0
        else { return nil }
        return Date(timeIntervalSince1970: core.reset)
    }
}
