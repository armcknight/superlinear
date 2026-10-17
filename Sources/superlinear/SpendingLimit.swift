import Foundation

/// The GitHub Actions spending limit the owner sets in GitHub's settings.
/// When it is used up, or a payment fails, GitHub starts no jobs in private
/// repositories: their check runs fail at once, with an annotation that says
/// why. Public repositories' standard runners are free, so they never stop.
///
/// The limit stops CI, not Claude: agents go on working and test locally. But
/// a check that never ran is not a failure to fix, so the daemon tells the two
/// apart, shows it, and reruns the stopped jobs once the limit is raised.
enum SpendingLimit {
    /// Whether a check run annotation says the job did not start because of
    /// the spending limit or a billing problem, such as "The job was not
    /// started because recent account payments have failed or your spending
    /// limit needs to be increased. Please check the 'Billing & plans' section
    /// of your settings", or "The job was not started because your account is
    /// locked due to a billing issue."
    static func isStopAnnotation(_ message: String) -> Bool {
        let text = message.lowercased()
        guard text.contains("not started") || text.contains("not been started") || text.contains("was not run")
        else { return false }
        return ["spending limit", "billing", "payment"].contains { text.contains($0) }
    }

    /// The conclusions of a run whose checks are failing.
    static let failedConclusions: Set<WorkflowRun.Conclusion> = [.failure, .startupFailure]

    /// The latest run of each workflow on each of `branches`, where it failed:
    /// the runs whose annotations may tell of the spending limit.
    static func failingRuns(_ runs: [WorkflowRunSummary], branches: Set<String>) -> [WorkflowRunSummary] {
        var latest: [String: WorkflowRunSummary] = [:]
        for run in runs where branches.contains(run.headBranch) {
            let key = "\(run.headBranch)\u{0}\(run.workflowName ?? "")"
            if let other = latest[key], other.createdAt >= run.createdAt { continue }
            latest[key] = run
        }
        return latest.values
            .filter { $0.status == .completed && $0.conclusion.map(failedConclusions.contains) ?? false }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// What became of a stopped run that was rerun, by the daemon or by the
    /// owner, to see whether the limit was raised.
    enum ProbeResult: Equatable {
        /// Its jobs started: the owner raised the limit, or the month changed.
        case started
        /// Its jobs were stopped again.
        case stillStopped
        /// It was not rerun, GitHub has not taken in the rerun, or its jobs
        /// wait for a runner.
        case pending
    }

    /// Reads the rerun of `run`, as `gh run list` reports it now, against the
    /// attempt it was at when it was found stopped. `stopped` says whether a
    /// failed attempt was stopped by the limit.
    static func probeResult(
        _ run: WorkflowRunSummary?, rerunFrom attempt: Int, stopped: () async -> Bool?
    ) async -> ProbeResult {
        guard let run, (run.attempt ?? 1) > attempt else { return .pending }
        switch run.status {
        case .queued, .waiting, .pending, .requested: return .pending
        case .completed: break
        case .inProgress, .unknown: return .started
        }
        guard run.conclusion.map(failedConclusions.contains) ?? false else { return .started }
        switch await stopped() {
        case true?: return .stillStopped
        case false?: return .started
        case nil: return .pending
        }
    }

    static let runListFields = "databaseId,headBranch,workflowName,status,conclusion,createdAt,attempt"

    /// The repository's newest 100 workflow runs.
    static func listRuns(in repoPath: String) throws -> [WorkflowRunSummary] {
        let data = try GitHubCLI.run(["run", "list", "--limit", "100", "--json", runListFields], in: repoPath)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([WorkflowRunSummary].self, from: data)
    }

    /// Whether the run's latest attempt was stopped by the limit: whether the
    /// annotations of its first failed job say so. All of a stopped run's jobs
    /// are stopped, so one is enough.
    static func wasStopped(runId: WorkflowRun.ID, in repoPath: String) throws -> Bool {
        let jobs = try GitHubCLI.run(
            ["api", "repos/{owner}/{repo}/actions/runs/\(runId.rawValue)/jobs",
             "--jq", #"[.jobs[] | select(.conclusion == "failure") | .id] | first // empty"#],
            in: repoPath)
        let jobId = String(decoding: jobs, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jobId.isEmpty else { return false }
        let annotations = try GitHubCLI.run(
            ["api", "repos/{owner}/{repo}/check-runs/\(jobId)/annotations", "--jq", ".[].message"], in: repoPath)
        return String(decoding: annotations, as: UTF8.self).split(whereSeparator: \.isNewline)
            .contains { isStopAnnotation(String($0)) }
    }

    /// Reruns the failed jobs of a run.
    static func rerunFailedJobs(runId: WorkflowRun.ID, in repoPath: String) throws {
        _ = try GitHubCLI.run(["run", "rerun", "\(runId.rawValue)", "--failed"], in: repoPath)
    }

    /// Whether the repository is private, the only kind the limit stops.
    static func isPrivate(repoPath: String) throws -> Bool {
        let data = try GitHubCLI.run(["repo", "view", "--json", "isPrivate", "--jq", ".isPrivate"], in: repoPath)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }
}

/// A workflow run as `gh run list` reports it, to look for stopped ones.
struct WorkflowRunSummary: Decodable, Sendable, Equatable {
    let databaseId: WorkflowRun.ID
    let headBranch: String
    let workflowName: String?
    let status: WorkflowRun.Status
    /// How a completed run ended; nil while it runs, or when GitHub reports a
    /// conclusion this build does not know.
    let conclusion: WorkflowRun.Conclusion?
    let createdAt: Date
    let attempt: Int?

    init(
        databaseId: WorkflowRun.ID, headBranch: String, workflowName: String?, status: WorkflowRun.Status,
        conclusion: WorkflowRun.Conclusion?, createdAt: Date, attempt: Int?
    ) {
        self.databaseId = databaseId
        self.headBranch = headBranch
        self.workflowName = workflowName
        self.status = status
        self.conclusion = conclusion
        self.createdAt = createdAt
        self.attempt = attempt
    }

    // `gh` reports an empty conclusion for a run still going.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        databaseId = try container.decode(WorkflowRun.ID.self, forKey: .databaseId)
        headBranch = try container.decode(String.self, forKey: .headBranch)
        workflowName = try container.decodeIfPresent(String.self, forKey: .workflowName)
        status = try container.decode(WorkflowRun.Status.self, forKey: .status)
        conclusion = .parse(try container.decodeIfPresent(String.self, forKey: .conclusion))
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        attempt = try container.decodeIfPresent(Int.self, forKey: .attempt)
    }

    private enum CodingKeys: String, CodingKey {
        case databaseId, headBranch, workflowName, status, conclusion, createdAt, attempt
    }
}

/// A workflow run whose jobs the spending limit stopped.
struct StoppedRun: Codable, Sendable, Equatable {
    var id: WorkflowRun.ID
    var branch: String
    var workflow: String?
    var createdAt: Date
    /// The run's attempt when it was found stopped, or rerun.
    var attempt: Int

    init(id: WorkflowRun.ID, branch: String, workflow: String?, createdAt: Date, attempt: Int) {
        self.id = id
        self.branch = branch
        self.workflow = workflow
        self.createdAt = createdAt
        self.attempt = attempt
    }

    init(_ run: WorkflowRunSummary) {
        self.init(
            id: run.databaseId, branch: run.headBranch, workflow: run.workflowName,
            createdAt: run.createdAt, attempt: run.attempt ?? 1)
    }
}

/// A repository's CI stopped by the spending limit. Kept in the state file,
/// so `superlinear status` can show it.
struct SpendingLimitStop: Codable, Sendable, Equatable {
    /// When the daemon first found a stopped run.
    var since: Date
    /// The stopped runs, newest first.
    var runs: [StoppedRun]
    /// When the daemon last reran one, or found the first, to wait an hour
    /// between reruns.
    var lastRerunAt: Date
    /// The run last rerun, until its jobs start or stop again.
    var probe: StoppedRun?

    /// How often a stopped run is rerun to see whether the limit was raised.
    static let rerunInterval: TimeInterval = 60 * 60

    init(since: Date, runs: [StoppedRun], lastRerunAt: Date, probe: StoppedRun?) {
        self.since = since
        self.runs = runs
        self.lastRerunAt = lastRerunAt
        self.probe = probe
    }

    /// The stop after a poll found `stopped` runs at `now`, or nil when there
    /// are none, as when the owner reran them by hand and they ran. A run
    /// being probed stays.
    static func updated(_ stop: SpendingLimitStop?, stopped: [StoppedRun], now: Date) -> SpendingLimitStop? {
        var runs = stopped.sorted { $0.createdAt > $1.createdAt }
        if let probe = stop?.probe, !runs.contains(where: { $0.id == probe.id }) { runs.append(probe) }
        guard !runs.isEmpty else { return nil }
        guard var stop else { return SpendingLimitStop(since: now, runs: runs, lastRerunAt: now, probe: nil) }
        stop.runs = runs
        return stop
    }

    /// The runs whose reruns are read at a poll: the probe first, then the
    /// others, any of which the owner may have rerun by hand.
    var watched: [StoppedRun] {
        guard let probe else { return runs }
        return [probe] + runs.filter { $0.id != probe.id }
    }

    /// The run to rerun now, if an hour has passed since the last rerun and
    /// none is being watched: the newest.
    func runToProbe(now: Date) -> StoppedRun? {
        guard probe == nil, now >= lastRerunAt.addingTimeInterval(Self.rerunInterval) else { return nil }
        return runs.first
    }

    /// The runs to rerun once `started`'s jobs started: newest first, at most
    /// one for each branch, and none on its branch, which ran again.
    func othersToRerun(after started: StoppedRun) -> [StoppedRun] {
        var branches: Set<String> = [started.branch]
        return runs.filter { run in
            run.id != started.id && branches.insert(run.branch).inserted
        }
    }

    /// The branches whose CI the limit stopped.
    var branches: Set<String> { Set(runs.map(\.branch)) }

    /// The line `superlinear status` prints about the stops in all
    /// repositories, or nil when there are none.
    static func rendered(_ stops: [SpendingLimitStop], now: Date) -> String? {
        guard let since = stops.map(\.since).min() else { return nil }
        let count = stops.count
        return "GitHub Actions spending limit: CI not started in \(count) repositor\(count == 1 ? "y" : "ies") "
            + "since \(StatusTime.clock(since, now: now))"
    }
}
