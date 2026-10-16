import Foundation

/// A planning job whose Claude session is running, or was when the daemon
/// last saw it. Kept in the state file, as an agent's run is, so a restarted
/// daemon finds it again.
struct PlanningRun: Codable, Sendable, Equatable {
    /// The Claude session, chosen by superlinear so it can be resumed by ID.
    var sessionId: String
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

/// What one planning job did, kept for the schedule and the standup.
struct PlanningRunRecord: Codable, Sendable, Equatable {
    var sessionId: String
    var startedAt: Date
    var endedAt: Date
    /// The default branch's head the job looked at, which the next job
    /// starts from.
    var head: String?
    /// What its Claude session used, when its transcript was found.
    var usage: AgentUsage?
    /// Proposals stored, and those the daemon refused as invalid or the same
    /// as one pending or rejected.
    var proposed: Int = 0
    var skipped: Int = 0
    /// Why the job failed, if it did.
    var error: String?
}

/// When planning jobs run.
enum PlanningSchedule {
    /// A poll starts a job once the last one is this old.
    static let interval: TimeInterval = 24 * 60 * 60
    /// The standup offers to run one once the last one is this old.
    static let standupOffer: TimeInterval = 12 * 60 * 60
    /// The runs kept per workspace.
    static let retainedRuns = 30

    /// The latest of `runs`, by start.
    static func last(_ runs: [PlanningRunRecord]) -> PlanningRunRecord? {
        runs.max { $0.startedAt < $1.startedAt }
    }

    /// Whether a job is due: none ran yet, or the last started `interval` or
    /// more ago.
    static func isDue(last: PlanningRunRecord?, now: Date = Date(), interval: TimeInterval = interval) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last.startedAt) >= interval
    }

    /// The head the next job starts from: that of the last job that ended
    /// without an error, so commits a failed job missed are looked at again.
    static func since(_ runs: [PlanningRunRecord]) -> String? {
        runs.filter { $0.error == nil && $0.head != nil }.max { $0.startedAt < $1.startedAt }?.head
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

    mutating func prune(now: Date = Date()) {
        proposals.removeAll { $0.createdAt < now.addingTimeInterval(-Self.retention) }
    }
}

/// The file `superlinear plan` writes, per workspace. Like the standup's, it
/// is apart from the state file, which only the daemon writes; the daemon
/// reads this one at each poll and takes in the proposals it lacks.
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
