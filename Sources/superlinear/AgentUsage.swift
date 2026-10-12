import Foundation

/// What an agent's Claude sessions used, read from their transcripts: the
/// tokens Claude reports for each message, and the time the agent was active.
struct AgentUsage: Sendable, Equatable {
    /// Input tokens, cache writes included.
    var inputTokens = 0
    var outputTokens = 0
    /// Input read back from the prompt cache, far cheaper than other input.
    var cacheReadTokens = 0
    /// The sum of the gaps between consecutive transcript entries, leaving out
    /// gaps longer than `idleLimit`, as while the machine slept or the agent
    /// waited to be resumed.
    var activeTime: TimeInterval = 0

    static let idleLimit: TimeInterval = 30 * 60

    /// Tokens other than cache reads.
    var tokens: Int { inputTokens + outputTokens }

    private struct Entry: Decodable {
        let timestamp: String?
        let message: Message?

        struct Message: Decodable {
            let id: String?
            let usage: Usage?
        }

        struct Usage: Decodable {
            let input_tokens: Int?
            let cache_creation_input_tokens: Int?
            let cache_read_input_tokens: Int?
            let output_tokens: Int?
        }
    }

    /// Adds up transcripts in Claude's JSON Lines format. Claude writes one
    /// line per content block, each repeating its message's usage, so each
    /// message is counted once. Subagents' transcripts count for tokens, but
    /// not for time: they run within the main session's time.
    static func of(_ transcripts: [(data: Data, isSubagent: Bool)]) -> AgentUsage {
        var usage = AgentUsage()
        var counted = Set<String>()
        var times: [Date] = []
        let decoder = JSONDecoder()
        let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        for (data, isSubagent) in transcripts {
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let entry = try? decoder.decode(Entry.self, from: line) else { continue }
                if !isSubagent, let timestamp = entry.timestamp, let date = try? format.parse(timestamp) {
                    times.append(date)
                }
                guard let message = entry.message, let tokens = message.usage else { continue }
                if let id = message.id, !counted.insert(id).inserted { continue }
                usage.inputTokens += (tokens.input_tokens ?? 0) + (tokens.cache_creation_input_tokens ?? 0)
                usage.cacheReadTokens += tokens.cache_read_input_tokens ?? 0
                usage.outputTokens += tokens.output_tokens ?? 0
            }
        }
        times.sort()
        for (earlier, later) in zip(times, times.dropFirst()) {
            let gap = later.timeIntervalSince(earlier)
            if gap <= idleLimit { usage.activeTime += gap }
        }
        return usage
    }
}

/// Claude's session transcripts, under ~/.claude/projects: one directory per
/// working directory, named after its path with each character other than a
/// letter or digit made a hyphen. An agent's worktree directory ends in
/// `-worktrees-<branch>`, so its sessions are found by branch, also after the
/// worktree is removed or the repository moved.
struct Transcripts: Sendable {
    let root: String
    private let names: [String]

    init(root: String = "\(Paths.home)/.claude/projects") {
        self.root = root
        names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
    }

    static func encoded(_ path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    func directories(forBranch branch: String) -> [String] {
        guard !branch.isEmpty else { return [] }
        let suffix = "-worktrees-" + Self.encoded(branch)
        return names.filter { $0.hasSuffix(suffix) }.sorted().map { "\(root)/\($0)" }
    }

    /// The usage of every session run on `branch`, or nil when none was found.
    func usage(forBranch branch: String) -> AgentUsage? {
        var transcripts: [(data: Data, isSubagent: Bool)] = []
        for directory in directories(forBranch: branch) {
            guard let enumerator = FileManager.default.enumerator(atPath: directory) else { continue }
            for case let path as String in enumerator where path.hasSuffix(".jsonl") {
                guard let data = FileManager.default.contents(atPath: "\(directory)/\(path)") else { continue }
                transcripts.append((data, path.contains("/")))
            }
        }
        return transcripts.isEmpty ? nil : AgentUsage.of(transcripts)
    }
}

/// A GitHub Actions workflow run, as `gh run list --json` reports it.
struct WorkflowRun: Codable, Sendable, Equatable {
    let headBranch: String
    let status: String
    let startedAt: Date?
    let updatedAt: Date?

    static let jsonFields = "headBranch,status,startedAt,updatedAt"

    /// How long a finished run took, start to end. Runs still going count
    /// once they finish.
    var duration: TimeInterval? {
        guard status == "completed", let startedAt, let updatedAt, updatedAt > startedAt else { return nil }
        return updatedAt.timeIntervalSince(startedAt)
    }

    /// The time finished runs took, summed per branch.
    static func time(byBranch runs: [WorkflowRun]) -> [String: TimeInterval] {
        runs.reduce(into: [:]) { totals, run in
            if let duration = run.duration { totals[run.headBranch, default: 0] += duration }
        }
    }

    /// The repository's newest 1,000 workflow runs, from `gh`.
    static func list(in repoPath: String) throws -> [WorkflowRun] {
        let data = try GitHubCLI.run(["run", "list", "--limit", "1000", "--json", jsonFields], in: repoPath)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([WorkflowRun].self, from: data)
    }
}

enum GitHubCLI {
    /// Runs `gh` with `arguments` in `repoPath`, from whose remotes it works
    /// out the GitHub repository, and returns its output.
    static func run(_ arguments: [String], in repoPath: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gh"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: repoPath)
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Read before waiting, or a full pipe would stall gh forever.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw StatusError.gitHub(text.isEmpty ? "gh exited \(process.terminationStatus)" : text)
        }
        return data
    }
}
