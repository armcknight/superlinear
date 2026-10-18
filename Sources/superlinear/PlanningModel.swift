import Foundation

/// The model a project-management session works on: the planning job, and
/// the sessions that answer the owner's comments. They run on Fable, which
/// has its own usage limit; once that is used up, they run on Opus until it
/// resets. Agents working on issues are not among them: they run on
/// `AgentRunner.model`.
enum PlanningModel: String, Codable, Sendable, Equatable {
    case fable
    case opus

    /// The one to use first.
    static let preferred = PlanningModel.fable
    /// The next best, while the preferred one's limit is used up.
    static let fallback = PlanningModel.opus

    /// The model to start a session on at `now`.
    static func current(limit: FableLimit?, now: Date) -> PlanningModel {
        guard let limit, !limit.isOver(now: now) else { return preferred }
        return fallback
    }

    /// The `claude` arguments that choose it.
    var arguments: [String] { ["--model", rawValue] }
}

/// The time Fable's own usage limit was used up, and when it resets: until
/// then, project-management sessions run on `PlanningModel.fallback`. Kept in
/// the state file, so a restarted daemon and `superlinear plan` know it.
struct FableLimit: Codable, Sendable, Equatable {
    /// When the limit was first hit.
    var since: Date
    /// When Claude said the limit resets, or `ClaudePause.fallbackDelay`
    /// after it was hit when it did not say.
    var until: ClaudeUsageLimit.ResetTime

    init(since: Date, until: ClaudeUsageLimit.ResetTime) {
        self.since = since
        self.until = until
    }

    /// The limit a Fable session hit at `now`.
    init(hit: ClaudeUsageLimit.Hit, now: Date) {
        let until = hit.resetAt.flatMap { $0.rawValue > now ? $0 : nil }
            ?? ClaudeUsageLimit.ResetTime(rawValue: now.addingTimeInterval(ClaudePause.fallbackDelay))
        self.init(since: now, until: until)
    }

    func isOver(now: Date) -> Bool { now >= until.rawValue }

    /// The line `superlinear status` prints about it.
    func rendered(now: Date) -> String {
        "Fable usage limit: planning and comment answers run on \(PlanningModel.fallback.rawValue) "
            + "until \(StatusTime.clock(until.rawValue, now: now))"
    }
}
