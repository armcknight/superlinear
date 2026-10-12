import Foundation

/// What `superlinear status` ends with: how many items each section holds
/// across all workspaces, what the agents' pull requests took, and the same
/// per workspace.
struct StatusSummary: Sendable {
    let reports: [WorkspaceReport]

    /// Each section heading with how many items it holds in all workspaces, in
    /// report order. Empty sections are left out.
    var counts: [(heading: String, count: Int)] {
        let reviews = reports.flatMap { $0.reviews ?? [] }
        // As in each report, open pull requests count once, for review where
        // they could be listed.
        let tasks = reports.flatMap { report in
            report.reviews == nil ? report.entries : report.entries.filter { $0.category != .openPullRequest }
        }
        let counts = [
            ("Awaiting review", reviews.filter { !$0.pullRequest.isDraft }.count),
            ("Draft pull requests", reviews.filter(\.pullRequest.isDraft).count),
        ] + TaskCategory.allCases.map { category in
            (category.heading, tasks.filter { $0.category == category }.count)
        }
        return counts.filter { $0.1 > 0 }
    }

    /// A measure taken of each pull request that has it.
    struct Metric {
        let name: String
        let values: [Double]
        let format: (Double) -> String

        var total: Double { values.reduce(0, +) }
        var mean: Double { total / Double(values.count) }
        var median: Double {
            let sorted = values.sorted()
            let middle = sorted.count / 2
            return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
        }
        var max: Double { values.max() ?? 0 }
    }

    /// The measures of `pullRequests`, leaving out those none has.
    static func metrics(_ pullRequests: [PullRequestStats]) -> [Metric] {
        func metric(_ name: String, _ format: @escaping (Double) -> String, _ value: (PullRequestStats) -> Double?) -> Metric {
            Metric(name: name, values: pullRequests.compactMap(value), format: format)
        }
        let count = { (value: Double) in compact(Int(value.rounded())) }
        return [
            metric("Lines added", count) { $0.additions.map(Double.init) },
            metric("Lines removed", count) { $0.deletions.map(Double.init) },
            metric("Files changed", count) { $0.changedFiles.map(Double.init) },
            metric("Tokens", count) { $0.usage.map { Double($0.tokens) } },
            metric("Cache reads", count) { $0.usage.map { Double($0.cacheReadTokens) } },
            metric("Agent time", duration) { $0.usage?.activeTime },
            metric("CI time", duration) { $0.ciTime },
        ].filter { !$0.values.isEmpty }
    }

    func rendered() -> String {
        var lines = ["Summary"]
        lines += Self.table([["Projects", "\(reports.count)"]] + counts.map { [$0.heading, "\($0.count)"] })
            .map { "  " + $0 }

        let pullRequests = reports.flatMap(\.pullRequestStats)
        let metrics = Self.metrics(pullRequests)
        if !metrics.isEmpty {
            let merged = pullRequests.filter(\.merged).count
            lines.append("")
            lines.append("  Per pull request (\(pullRequests.count) from agents: \(pullRequests.count - merged) open, \(merged) merged)")
            let rows = [["", "total", "mean", "median", "max"]] + metrics.map { metric in
                [metric.name] + [metric.total, metric.mean, metric.median, metric.max].map(metric.format)
            }
            lines += Self.table(rows).map { "    " + $0 }
        }

        let all = reports.flatMap(\.entries)
        let usage = all.compactMap(\.usage)
        if !usage.isEmpty {
            let ciTime = all.compactMap(\.ciTime).reduce(0, +)
            let totals = [
                "\(Self.compact(usage.map(\.tokens).reduce(0, +))) tokens",
                "\(Self.compact(usage.map(\.cacheReadTokens).reduce(0, +))) cache reads",
                "\(Self.duration(usage.map(\.activeTime).reduce(0, +))) agent time",
            ] + (all.contains { $0.ciTime != nil } ? ["\(Self.duration(ciTime)) CI time"] : [])
            lines.append("")
            lines.append("  All \(all.count) tracked tasks: " + totals.joined(separator: ", "))
        }

        let projects = reports.filter { !$0.entries.isEmpty || !$0.pullRequestStats.isEmpty }
        if !projects.isEmpty {
            lines.append("")
            lines.append("  By project")
            let rows = [["", "tasks", "PRs", "+lines", "-lines", "tokens", "agent time", "CI time"]]
                + projects.map { report in
                    let pullRequests = report.pullRequestStats
                    let usage = pullRequests.compactMap(\.usage)
                    let ciTimes = pullRequests.compactMap(\.ciTime)
                    return [
                        report.name,
                        "\(report.entries.count)",
                        "\(pullRequests.count)",
                        Self.compact(pullRequests.compactMap(\.additions).reduce(0, +)),
                        Self.compact(pullRequests.compactMap(\.deletions).reduce(0, +)),
                        usage.isEmpty ? "-" : Self.compact(usage.map(\.tokens).reduce(0, +)),
                        usage.isEmpty ? "-" : Self.duration(usage.map(\.activeTime).reduce(0, +)),
                        ciTimes.isEmpty ? "-" : Self.duration(ciTimes.reduce(0, +)),
                    ]
                }
            lines += Self.table(rows).map { "    " + $0 }
        }
        return lines.joined(separator: "\n")
    }

    /// Rows with the first column aligned left and the others right.
    static func table(_ rows: [[String]]) -> [String] {
        let columns = rows.map(\.count).max() ?? 0
        let widths = (0..<columns).map { column in rows.map { column < $0.count ? $0[column].count : 0 }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { column, cell in
                let pad = String(repeating: " ", count: widths[column] - cell.count)
                return column == 0 ? cell + pad : pad + cell
            }.joined(separator: "  ").trimmingTrailingWhitespace()
        }
    }

    /// 950, 12.3k, 123k, 4.5M, 1.2B.
    static func compact(_ value: Int) -> String {
        let magnitude = abs(Double(value))
        for (limit, suffix) in [(1e9, "B"), (1e6, "M"), (1e3, "k")] where magnitude >= limit {
            let scaled = Double(value) / limit
            return (abs(scaled) < 100 ? String(format: "%.1f", scaled) : String(format: "%.0f", scaled)) + suffix
        }
        return "\(value)"
    }

    /// 0m, 14m, 2h 05m, 3d 04h.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 24 * 60 { return String(format: "%dh %02dm", minutes / 60, minutes % 60) }
        let hours = minutes / 60
        return String(format: "%dd %02dh", hours / 24, hours % 24)
    }
}

/// What one of the agents' pull requests took.
struct PullRequestStats: Sendable, Equatable {
    let url: String
    let merged: Bool
    var additions: Int? = nil
    var deletions: Int? = nil
    var changedFiles: Int? = nil
    /// What the Claude sessions on its branch used, if any were found.
    var usage: AgentUsage? = nil
    /// Time its branch's finished CI runs took, if CI runs were listed.
    var ciTime: TimeInterval? = nil

    /// The pull requests of tasks that finished with one open or merged, then
    /// the open ones listed for review that no task has, as when opened before
    /// the daemon tracked the issue. `measure` gives a branch's usage and CI
    /// time.
    static func of(
        tasks: [TaskEntry], reviews: [ReviewEntry],
        measure: (String) -> (usage: AgentUsage?, ciTime: TimeInterval?)
    ) -> [PullRequestStats] {
        var stats: [PullRequestStats] = tasks.compactMap { task in
            guard let pullRequest = task.pullRequest,
                [.openPullRequest, .merged, .completed].contains(task.category)
            else { return nil }
            return PullRequestStats(
                url: pullRequest.url, merged: pullRequest.state == .merged,
                additions: pullRequest.additions, deletions: pullRequest.deletions,
                changedFiles: pullRequest.changedFiles, usage: task.usage, ciTime: task.ciTime
            )
        }
        let counted = Set(stats.map(\.url))
        for review in reviews where !counted.contains(review.pullRequest.url) {
            let pullRequest = review.pullRequest
            let (usage, ciTime) = measure(pullRequest.headRefName)
            stats.append(PullRequestStats(
                url: pullRequest.url, merged: false,
                additions: pullRequest.additions, deletions: pullRequest.deletions,
                changedFiles: pullRequest.changedFiles, usage: usage, ciTime: ciTime
            ))
        }
        return stats
    }
}
