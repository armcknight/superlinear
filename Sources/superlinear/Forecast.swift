import Foundation
import Tagged

/// A project's or milestone's health, as Linear's project updates take it.
enum ProjectHealth: String, Codable, Sendable, Comparable, CaseIterable {
    case onTrack, atRisk, offTrack

    /// How bad it is, so the worst of several can be found.
    private var severity: Int {
        switch self {
        case .onTrack: 0
        case .atRisk: 1
        case .offTrack: 2
        }
    }

    static func < (a: ProjectHealth, b: ProjectHealth) -> Bool { a.severity < b.severity }

    var rendered: String {
        switch self {
        case .onTrack: "on track"
        case .atRisk: "at risk"
        case .offTrack: "off track"
        }
    }
}

enum LinearMilestone { typealias ID = Tagged<LinearMilestone, String> }

/// A completed issue an agent worked on, as the forecast learns from it.
struct CompletedIssueSample: Sendable, Equatable {
    var identifier: LinearIssue.Identifier
    var mergedAt: Date
    /// The time the agent's Claude sessions were active, when their
    /// transcripts were found.
    var agentTime: TimeInterval?
    /// From the issue's move into a started state to its pull request's
    /// merge, when Linear has the start.
    var startToMerge: TimeInterval?
}

/// What the workspace's recent completed issues took, the forecast's only input
/// besides the open issues.
struct ForecastHistory: Sendable, Equatable {
    /// How many of the most recently merged issues count.
    static let sampleSize = 30

    /// The median time an agent was active on an issue.
    var agentTime: TimeInterval
    /// The median time from an issue's start to its pull request's merge.
    var startToMerge: TimeInterval
    /// The number of issues the medians come from.
    var count: Int

    /// The medians of the last `sampleSize` issues merged, or nil when none
    /// has an agent time or none a start-to-merge time.
    static func of(_ samples: [CompletedIssueSample]) -> ForecastHistory? {
        let recent = samples.sorted { $0.mergedAt > $1.mergedAt }.prefix(sampleSize)
        guard let agentTime = median(recent.compactMap(\.agentTime)),
              let startToMerge = median(recent.compactMap(\.startToMerge))
        else { return nil }
        return ForecastHistory(agentTime: agentTime, startToMerge: startToMerge, count: recent.count)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}

/// An open issue to schedule.
struct ForecastIssue: Sendable, Equatable {
    var id: LinearIssue.ID
    var identifier: LinearIssue.Identifier
    /// The open issues blocking it. Those not among the issues scheduled are
    /// left out of the schedule.
    var blockers: [LinearIssue.ID] = []
    /// When it moved into a started state, if it has.
    var startedAt: Date?
}

/// A milestone and its forecast.
struct MilestoneForecast: Sendable, Equatable {
    var id: LinearMilestone.ID
    var name: String
    var projectId: LinearProject.ID
    var projectName: String
    /// The first day after which it is late.
    var targetDate: Date?
    var openIssues: Int
    /// When its last open issue is forecast to merge; nil without a history.
    var forecast: Date?
    /// Nil without a target date, or without a forecast before the target
    /// date has passed.
    var health: ProjectHealth?
}

enum Forecast {
    /// When each issue is forecast to merge: each takes an agent for the
    /// median agent time and merges the median start-to-merge time after it
    /// starts. At most `agents` run at once, and an issue starts once its
    /// blockers merge. Started issues keep their agents first; then the
    /// issue that can start soonest goes next, earlier in `issues` first.
    static func schedule(
        _ issues: [ForecastIssue], history: ForecastHistory, agents: Int, now: Date
    ) -> [LinearIssue.ID: Date] {
        let agentTime = history.agentTime
        let mergeTime = max(history.startToMerge, agentTime)
        var free = Array(repeating: now, count: max(1, agents))
        var merges: [LinearIssue.ID: Date] = [:]
        let ids = Set(issues.map(\.id))

        /// Takes the agent free soonest until `end`.
        func takeAgent(until end: Date) {
            let index = free.indices.min { free[$0] < free[$1] }!
            free[index] = max(free[index], end)
        }

        for issue in issues.filter({ $0.startedAt != nil }).sorted(by: { $0.startedAt! < $1.startedAt! }) {
            let started = issue.startedAt!
            let agentEnd = started.addingTimeInterval(agentTime)
            if agentEnd > now { takeAgent(until: agentEnd) }
            merges[issue.id] = max(now, started.addingTimeInterval(mergeTime))
        }

        var waiting = issues.filter { $0.startedAt == nil }
        while !waiting.isEmpty {
            let earliestFree = free.min()!
            // Blockers not yet scheduled hold an issue back, unless every
            // issue left waits on one, as in a cycle.
            let unblocked = waiting.filter { issue in
                issue.blockers.allSatisfy { !ids.contains($0) || merges[$0] != nil }
            }
            let candidates = unblocked.isEmpty ? waiting : unblocked
            func start(_ issue: ForecastIssue) -> Date {
                let ready = issue.blockers.compactMap { merges[$0] }.max() ?? now
                return max(ready, earliestFree)
            }
            var best = 0
            for index in candidates.indices.dropFirst() where start(candidates[index]) < start(candidates[best]) {
                best = index
            }
            let issue = candidates[best]
            let begin = start(issue)
            takeAgent(until: begin.addingTimeInterval(agentTime))
            merges[issue.id] = begin.addingTimeInterval(mergeTime)
            waiting.removeAll { $0.id == issue.id }
        }
        return merges
    }

    /// A milestone's health: off track once its target date has passed with
    /// issues open, at risk when forecast to finish after it, on track
    /// otherwise. `targetDate` is the first day after which it is late.
    static func health(targetDate: Date?, openIssues: Int, forecast: Date?, now: Date) -> ProjectHealth? {
        guard let targetDate else { return nil }
        let deadline = Calendar.current.date(byAdding: .day, value: 1, to: targetDate) ?? targetDate
        guard openIssues > 0 else { return .onTrack }
        if deadline <= now { return .offTrack }
        guard let forecast else { return nil }
        return forecast > deadline ? .atRisk : .onTrack
    }
}
