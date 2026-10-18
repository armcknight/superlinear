import Foundation

/// Something the daemon did on its own, kept in the state file so that
/// `superlinear status` can show the owner what happened lately.
struct ActivityEvent: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        /// An agent started on a new issue.
        case agentStarted
        /// An agent for a new issue ended with success.
        case agentFinished
        /// An agent ended with a failure status.
        case agentFailed
        /// An agent ended without a status, or the daemon gave up on it.
        case agentStopped
        /// An agent addressed a review and ended with success.
        case reviewAddressed
        /// An agent merged the base branch into a conflicting pull request and
        /// ended with success.
        case conflictsResolved
        /// The daemon marked an issue done in Linear after its pull request merged.
        case issueCompleted
        /// The daemon merged the branch below a stacked pull request into it.
        case restacked
        /// The pull request below a stacked one was closed without a merge,
        /// so the daemon made the stacked one a draft.
        case stackBaseClosed
    }

    var time: Date
    var kind: Kind
    var identifier: LinearIssue.Identifier
    /// A pull request URL, an exit status, or why the daemon gave up.
    var detail: String?

    /// How long events stay in the state file.
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    /// The line `superlinear status` prints for it.
    var rendered: String {
        let text = switch kind {
        case .agentStarted: "agent started on \(identifier)"
        case .agentFinished: "agent finished \(identifier)"
        case .agentFailed: "agent failed on \(identifier)"
        case .agentStopped: "agent stopped on \(identifier)"
        case .reviewAddressed: "review addressed on \(identifier)"
        case .conflictsResolved: "conflicts resolved on \(identifier)"
        case .issueCompleted: "\(identifier) completed in Linear after its merge"
        case .restacked: "merged the branch below \(identifier)'s pull request into it"
        case .stackBaseClosed: "\(identifier)'s pull request became a draft: the one below it was closed without a merge"
        }
        return detail.map { "\(text): \($0)" } ?? text
    }

    /// The event for a run that ended with `status`.
    static func finished(_ run: AgentRun, status: Int32?, time: Date = Date()) -> ActivityEvent {
        switch status {
        case 0?:
            if let review = run.review {
                return ActivityEvent(time: time, kind: .reviewAddressed, identifier: run.identifier, detail: review.url)
            }
            if let conflict = run.conflict {
                return ActivityEvent(time: time, kind: .conflictsResolved, identifier: run.identifier, detail: conflict.url)
            }
            return ActivityEvent(time: time, kind: .agentFinished, identifier: run.identifier)
        case let status?:
            return ActivityEvent(time: time, kind: .agentFailed, identifier: run.identifier, detail: "exit status \(status)")
        case nil:
            return ActivityEvent(time: time, kind: .agentStopped, identifier: run.identifier, detail: "no exit status")
        }
    }
}
