import Foundation

/// `superlinear proposals`: each workspace's pending proposals, then those
/// decided recently, from the state file.
enum ProposalsCommand {
    /// How far back decided proposals are listed.
    static let recentWindow: TimeInterval = 7 * 24 * 60 * 60

    static func run(configPath: String?, workspace: String?) -> Int32 {
        let config: Config
        do {
            config = try Config.load(from: configPath)
        } catch {
            print("[superlinear] Failed to load config: \(error)")
            return 1
        }
        var names = config.workspaces.map(\.name)
        if let workspace {
            guard names.contains(workspace) else {
                print("[superlinear] No workspace named \(workspace). Workspaces: \(names.joined(separator: ", "))")
                return 1
            }
            names = [workspace]
        }
        let state = State.loadWithStandups()
        print(names.map { rendered(state.proposals(workspace: $0), workspace: $0) }.joined(separator: "\n\n"))
        return 0
    }

    static func rendered(_ proposals: [Proposal], workspace: String, now: Date = Date()) -> String {
        let pending = proposals.filter { $0.status == .pending }.sorted { $0.createdAt < $1.createdAt }
        let recent = proposals
            .filter { $0.status != .pending && ($0.decidedAt ?? $0.createdAt) >= now.addingTimeInterval(-recentWindow) }
            .sorted { ($0.decidedAt ?? $0.createdAt) > ($1.decidedAt ?? $1.createdAt) }
        var lines = [workspace]
        if pending.isEmpty && recent.isEmpty {
            lines.append("  No proposals")
            return lines.joined(separator: "\n")
        }
        if !pending.isEmpty {
            lines.append("  Pending (\(pending.count))")
            lines += pending.flatMap { describe($0, now: now) }
        }
        if !recent.isEmpty {
            lines.append("  Recent (\(recent.count))")
            lines += recent.flatMap { describe($0, now: now) }
        }
        return lines.joined(separator: "\n")
    }

    static func describe(_ proposal: Proposal, now: Date = Date()) -> [String] {
        let target = "\(proposal.target.kind.rawValue) \(proposal.target.name ?? proposal.target.rawID)"
        var status = switch proposal.status {
        case .pending: proposal.trust == .auto ? "auto" : "awaiting standup"
        case .applied: "applied"
        case .rejected: "rejected"
        case .expired: "expired"
        }
        if let decided = proposal.decidedAt { status += " \(StatusTime.rendered(decided, now: now))" }
        var lines = [
            "    \(proposal.id.rawValue.prefix(8))  \(proposal.kind.rawValue) → \(target)  [\(status)]",
            "      proposed \(StatusTime.rendered(proposal.createdAt, now: now))",
            "      reason: \(proposal.reason)",
            "      \(proposal.source.line.replacingOccurrences(of: "Source: ", with: "source: "))",
        ]
        if let reason = proposal.rejectionReason { lines.append("      rejected: \(reason)") }
        if let note = proposal.reviewNote { lines.append("      review again: \(note)") }
        if let error = proposal.lastError { lines.append("      last error: \(error)") }
        lines += change(proposal.payload).map { "      " + $0 }
        return lines
    }

    /// The change itself, with a diff for an edit.
    static func change(_ payload: ProposalPayload) -> [String] {
        switch payload {
        case .createIssue(_, _, let title, let description, _):
            return ["title: \(title)"] + description.split(separator: "\n", omittingEmptySubsequences: false).map { "| \($0)" }
        case .editIssue(let old, let new), .changeSpec(let old, let new):
            return LineDiff.lines(from: old, to: new)
        case .addRelation(let relatedIssueId, let type):
            return ["\(type) \(relatedIssueId)"]
        case .postProjectUpdate(let body, let health):
            return ["health: \(health?.rendered ?? "none")"]
                + body.split(separator: "\n", omittingEmptySubsequences: false).map { "| \($0)" }
        case .closeIssue, .promoteIssue:
            return []
        }
    }
}

/// A line diff of two texts: kept lines start with two spaces, removed ones
/// with `- `, added ones with `+ `, by their longest common subsequence.
enum LineDiff {
    static func lines(from old: String, to new: String) -> [String] {
        let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let b = new.isEmpty ? [] : new.components(separatedBy: "\n")
        // common[i][j]: the longest common subsequence of a[i...] and b[j...].
        var common = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                common[i][j] = a[i] == b[j] ? common[i + 1][j + 1] + 1 : max(common[i + 1][j], common[i][j + 1])
            }
        }
        var result: [String] = []
        var (i, j) = (0, 0)
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                result.append("  \(a[i])")
                (i, j) = (i + 1, j + 1)
            } else if i < a.count, j == b.count || common[i + 1][j] >= common[i][j + 1] {
                result.append("- \(a[i])")
                i += 1
            } else {
                result.append("+ \(b[j])")
                j += 1
            }
        }
        return result
    }
}
