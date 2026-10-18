import Foundation

/// A planning job whose Claude session is running, or was when the daemon
/// last saw it. Kept in the state file, as an agent's run is, so a restarted
/// daemon finds it again.
struct PlanningRun: Codable, Sendable, Equatable {
    /// The Claude session, chosen by superlinear so it can be resumed by ID.
    var sessionId: ClaudeSession.ID
    var startedAt: Date
    /// The default-branch worktree the session runs in.
    var worktreePath: String
    /// The wrapper process running Claude, once launched.
    var pid: Int32?
    /// The kernel's start time for `pid`, so a reused pid is not mistaken for it.
    var processStartedAt: Date?
    /// How many times the session was resumed after an interruption.
    var resumes: Int = 0
}

/// What one planning job did, kept for the trigger and `superlinear status`.
struct PlanningRunRecord: Codable, Sendable, Equatable {
    var sessionId: ClaudeSession.ID
    var startedAt: Date
    var endedAt: Date
    /// The default branch's head the job looked at, which the next job
    /// starts from, and which a later poll compares the branch against.
    var head: GitCommit.SHA?
    /// What its Claude session used, when its transcript was found.
    var usage: AgentUsage?
    /// Proposals stored, and those the daemon refused as invalid or the same
    /// as one pending or rejected.
    var proposed: Int = 0
    var skipped: Int = 0
    /// Why the job failed, if it did.
    var error: String?
}

/// Why a planning job starts: a change that may have moved the project,
/// found at a poll, or a person asking.
enum PlanningTrigger: Equatable, Sendable, CustomStringConvertible {
    /// The workspace has had no job yet.
    case firstJob
    /// The default branch's head is not the one the last job looked at: a
    /// pull request merged, or commits were pushed outside one.
    case newCommits(GitCommit.SHA)
    /// Issues were completed since the last job ended, in Linear or by the
    /// daemon after a merge.
    case completedIssues([LinearIssue.Identifier])
    /// `superlinear plan` asked for it.
    case onDemand

    /// A clause that follows "because" or "since the last job".
    var description: String {
        switch self {
        case .firstJob: "no job has run for the workspace yet"
        case .newCommits(let head): "the default branch moved to \(head.short)"
        case .completedIssues(let issues):
            issues.count == 1
                ? "\(issues[0]) was completed"
                : "\(issues.dropLast().map(\.rawValue).joined(separator: ", ")) and \(issues[issues.count - 1]) were completed"
        case .onDemand: "`superlinear plan` asked for one"
        }
    }
}

/// The planning jobs a workspace has had, the daemon's and
/// `superlinear plan`'s together.
enum PlanningHistory {
    /// The runs kept per workspace.
    static let retainedRuns = 30
    /// How far back the first job of a workspace looks, in commits and in
    /// completed issues, having no earlier job to start from.
    static let firstJobLookback: TimeInterval = 24 * 60 * 60

    /// The latest of `runs`, by start.
    static func last(_ runs: [PlanningRunRecord]) -> PlanningRunRecord? {
        runs.max { $0.startedAt < $1.startedAt }
    }

    /// The head the next job starts from: that of the last job that ended
    /// without an error, so commits a failed job missed are looked at again.
    static func since(_ runs: [PlanningRunRecord]) -> GitCommit.SHA? {
        runs.filter { $0.error == nil && $0.head != nil }.max { $0.startedAt < $1.startedAt }?.head
    }

    /// The head the branch is compared against at a poll: that of the last
    /// job, failed or not, so a broken job is not tried again until the
    /// branch moves, or else `since`.
    static func lastHead(_ runs: [PlanningRunRecord]) -> GitCommit.SHA? {
        last(runs)?.head ?? since(runs)
    }

    /// `runs` with `record` added and only the newest `retainedRuns` kept.
    static func appending(_ record: PlanningRunRecord, to runs: [PlanningRunRecord]) -> [PlanningRunRecord] {
        Array((runs + [record]).sorted { $0.startedAt < $1.startedAt }.suffix(retainedRuns))
    }
}

/// What `superlinear plan` did for one workspace.
struct WorkspacePlanning: Codable, Sendable, Equatable {
    var runs: [PlanningRunRecord] = []
    /// The proposals its jobs stored, for the daemon to take in.
    var proposals: [Proposal] = []
    /// The job running now, so the daemon does not start one beside it.
    var running: PlanningRun?

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runs = try container.decodeIfPresent([PlanningRunRecord].self, forKey: .runs) ?? []
        proposals = try container.decodeIfPresent([Proposal].self, forKey: .proposals) ?? []
        running = try container.decodeIfPresent(PlanningRun.self, forKey: .running)
    }

    /// How long proposals stay, once the daemon has long since taken them in.
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    mutating func prune(now: Date) {
        proposals.removeAll { $0.createdAt < now.addingTimeInterval(-Self.retention) }
    }
}

/// The file `superlinear plan` writes, per workspace. It is apart from the
/// state file, which only the daemon writes; the daemon reads this one at
/// each poll and takes in the proposals it lacks.
struct PlanningRecord: Codable, Sendable, Equatable {
    var workspaces: [String: WorkspacePlanning] = [:]

    static func fileURL(home: String = Paths.home) -> URL {
        URL(fileURLWithPath: "\(home)/.local/share/superlinear/planning.json")
    }

    static func load(from url: URL = fileURL()) -> PlanningRecord {
        guard let data = try? Data(contentsOf: url) else { return PlanningRecord() }
        do {
            return try decoded(from: data)
        } catch {
            print("[superlinear] Could not read \(url.path), starting with no planning runs: \(error)")
            return PlanningRecord()
        }
    }

    func save(to url: URL = fileURL()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmpURL = url.appendingPathExtension("tmp")
        try encoded().write(to: tmpURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decoded(from data: Data) throws -> PlanningRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PlanningRecord.self, from: data)
    }

    subscript(workspace: String) -> WorkspacePlanning {
        get { workspaces[workspace] ?? WorkspacePlanning() }
        set { workspaces[workspace] = newValue }
    }
}
