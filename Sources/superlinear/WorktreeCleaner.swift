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

    /// The retroactive part of the startup sweep: removes, with `work
    /// finish`, each worktree under `worktrees/` and its branch whose pull request merged and
    /// that has no commit after the merged head, unless an agent's run or a
    /// merge watch has it (`skip`). The removal at a merge is tried once, so
    /// this also clears those it could not do, such as worktrees with
    /// submodules before `work` could remove them. `work finish` itself
    /// refuses a worktree with changes, or with submodule work that would be
    /// lost, and that refusal is returned as an error.
    func finishMerged(repoPath: String, skip: Set<String>) async -> (removed: [String], errors: [String]) {
        let protected = StaleBranches.protectedBranches(repoPath: repoPath)
        let branches = StaleBranches.localBranches(repoPath: repoPath).filter { !protected.contains($0.name) }
        guard !branches.isEmpty else { return ([], []) }
        let pullRequests: [PullRequest]
        do {
            pullRequests = try PullRequest.list(in: repoPath)
        } catch {
            return ([], ["Could not list pull requests to find merged branches: \(error)"])
        }
        let stale = StaleBranches.find(
            branches: branches, pullRequests: pullRequests, protected: protected, inFlight: skip,
            worktreesRoot: "\(repoPath)/worktrees"
        )
        let worktrees = Dictionary(uniqueKeysWithValues: branches.compactMap { b in b.worktree.map { (b.name, $0) } })
        var removed: [String] = []
        var errors: [String] = []
        // Only branches with a worktree that `work start` made: a branch alone
        // takes no space, and may be one of your own.
        let made = stale.filter { worktrees[$0.branch]?.hasPrefix("\(repoPath)/worktrees/") == true }
        for branch in StaleBranches.removable(StaleBranches.countUnpushed(made, repoPath: repoPath)) {
            // `work finish` deletes a worktree's ignored files, such as .env,
            // before it finds that the worktree has changes and stops, so a
            // worktree with changes, in it or in its submodules, is left alone.
            if let worktree = worktrees[branch.branch], Self.hasChanges(worktree: worktree) {
                errors.append("Left merged \(branch.branch) in place: its worktree has changes not committed (\(worktree))")
                continue
            }
            do {
                _ = try await checker.run(["work", "finish", branch.branch], in: repoPath)
                removed.append("Removed \(branch.branch), \(branch.detail())")
            } catch {
                errors.append("Could not remove merged \(branch.branch): \(error)")
            }
        }
        return (removed, errors)
    }

    /// Whether the worktree has changes that are not committed, in its files
    /// or its submodules. Ignored files do not count. A worktree git cannot
    /// read counts as having changes.
    static func hasChanges(worktree: String) -> Bool {
        guard let status = Git.run(["status", "--porcelain", "--ignore-submodules=none"], in: worktree) else { return true }
        return !status.isEmpty
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
