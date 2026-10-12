import Foundation

/// Frees the build output agents leave behind — SwiftPM `.build` directories
/// and Xcode DerivedData — through `work clean`, which knows where a
/// worktree's DerivedData lives. Merged worktrees are removed whole, with their
/// DerivedData, by `work finish`.
///
/// As agents go, each worktree is cleaned when its agent ends: by then it has
/// pushed its work and opened its pull request. At startup, every worktree
/// whose agent is not running is cleaned if its build output has sat idle for
/// an hour, which spares one in use by hand, and DerivedData of worktrees since
/// removed goes too. The daemon restarts on every upgrade, config edit and
/// login, so anything missed is caught then.
struct WorktreeCleaner: Sendable {
    static let idleMinutes = 60

    let checker = PullRequestChecker()

    /// A linked worktree as `git worktree list --porcelain` reports it.
    struct Worktree: Equatable {
        let path: String
        /// The checked-out branch, or nil when the worktree's HEAD is detached.
        let branch: String?
    }

    /// The linked worktrees in `git worktree list --porcelain` output, leaving
    /// out the main checkout, which is always listed first.
    static func linkedWorktrees(_ porcelain: String) -> [Worktree] {
        let blocks = porcelain.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        return blocks.dropFirst().compactMap { block in
            var path: String?
            var branch: String?
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
                if line.hasPrefix("branch refs/heads/") { branch = String(line.dropFirst("branch refs/heads/".count)) }
            }
            return path.map { Worktree(path: $0, branch: branch) }
        }
    }

    /// Cleans the worktree of an agent that has ended. Returns `work`'s
    /// summary line, such as "Freed 2.1 GB for linear/sl-1-x".
    func cleanAfterAgent(branch: String, repoPath: String) async throws -> String? {
        try await summary(of: ["work", "clean", branch], in: repoPath)
    }

    /// The startup sweep for one repository. `running` holds the branches of
    /// agents running now, whose worktrees are left alone. Returns `work`'s
    /// summary lines for what was freed.
    func sweep(repoPath: String, running: Set<String>) async -> (freed: [String], errors: [String]) {
        var freed: [String] = []
        var errors: [String] = []
        let worktrees: [Worktree]
        do {
            let output = try await checker.run(["git", "worktree", "list", "--porcelain"], in: repoPath)
            worktrees = Self.linkedWorktrees(String(decoding: output, as: UTF8.self))
        } catch {
            return ([], ["Could not list worktrees: \(error)"])
        }
        for branch in worktrees.compactMap(\.branch) where !running.contains(branch) {
            do {
                if let line = try await summary(
                    of: ["work", "clean", branch, "--idle-minutes", "\(Self.idleMinutes)"], in: repoPath
                ), line.hasPrefix("Freed") {
                    freed.append(line)
                }
            } catch {
                errors.append("Could not clean the worktree for \(branch): \(error)")
            }
        }
        do {
            if let line = try await summary(of: ["work", "clean", "--orphans"], in: repoPath), line.hasPrefix("Freed") {
                freed.append(line)
            }
        } catch {
            errors.append("Could not clean DerivedData of removed worktrees: \(error)")
        }
        return (freed, errors)
    }

    /// Runs `arguments` and returns the last line of their output, where
    /// `work clean` sums up what it did.
    private func summary(of arguments: [String], in directory: String) async throws -> String? {
        let output = try await checker.run(arguments, in: directory)
        return String(decoding: output, as: UTF8.self)
            .split(separator: "\n").last.map(String.init)
    }
}
