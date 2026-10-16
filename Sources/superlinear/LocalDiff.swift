import Foundation

/// A pull request's size as the local repository sees it.
///
/// GitHub measures a pull request from where its branch forked off the base
/// branch on GitHub. An agent forks its branch off the local base branch,
/// which can be ahead of GitHub's, as when local commits are not yet pushed:
/// then GitHub counts those commits as part of each pull request. The local
/// base can also be behind, when not pulled. So the size is measured from the
/// later of the two fork points.
struct LocalDiff: Sendable, Equatable {
    var changedFiles = 0
    var additions = 0
    var deletions = 0
    /// The fork point off the local base branch is later than the one off
    /// GitHub's: the pull request carries local commits GitHub's base lacks.
    var forkedAheadOfOrigin = false

    /// Measures `branch`, or `origin/<branch>` when no local branch has that
    /// name, against `base` and `origin/<base>`. Nil when the branch or both
    /// bases are missing, or git fails.
    static func measure(branch: String, base: String, in repoPath: String) -> LocalDiff? {
        func git(_ arguments: String...) -> String? { Git.run(arguments, in: repoPath) }
        guard
            let tip = git("rev-parse", "--verify", "--quiet", "refs/heads/\(branch)^{commit}")
                ?? git("rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(branch)^{commit}")
        else { return nil }
        let local = git("merge-base", "refs/heads/\(base)", tip)
        let origin = git("merge-base", "refs/remotes/origin/\(base)", tip)

        var diff = LocalDiff()
        let fork: String
        switch (local, origin) {
        case let (local?, origin?) where local != origin:
            // Whichever descends from the other is later. Should they have
            // diverged, GitHub's is the one the pull request is reviewed on.
            if git("merge-base", "--is-ancestor", origin, local) != nil {
                fork = local
                diff.forkedAheadOfOrigin = true
            } else {
                fork = origin
            }
        case let (local?, _): fork = local
        case let (nil, origin?): fork = origin
        case (nil, nil): return nil
        }

        guard let stat = git("diff", "--shortstat", fork, tip) else { return nil }
        diff.read(shortstat: stat)
        return diff
    }

    /// Reads `git diff --shortstat`, such as
    /// "3 files changed, 10 insertions(+), 2 deletions(-)". Git leaves out
    /// parts that are zero, and prints nothing for no change.
    mutating func read(shortstat: String) {
        for part in shortstat.split(separator: ",") {
            let words = part.split(separator: " ")
            guard let count = words.first.flatMap({ Int($0) }), words.count > 1 else { continue }
            switch words[1] {
            case "file", "files": changedFiles = count
            case let word where word.hasPrefix("insertion"): additions = count
            case let word where word.hasPrefix("deletion"): deletions = count
            default: break
            }
        }
    }

    /// How many commits `base` has that `origin/<base>` lacks, if both exist.
    static func commitsAhead(base: String, in repoPath: String) -> Int? {
        Git.run(["rev-list", "--count", "refs/remotes/origin/\(base)..refs/heads/\(base)"], in: repoPath).flatMap { Int($0) }
    }
}

enum Git {
    /// Runs git in `repoPath` and returns its trimmed output, or nil when it
    /// exits non-zero.
    static func run(_ arguments: [String], in repoPath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", repoPath] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The branch `origin/HEAD` names, or nil when it names none.
    static func defaultBranch(in repoPath: String) -> String? {
        guard let ref = run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: repoPath), ref.hasPrefix("origin/")
        else { return nil }
        return String(ref.dropFirst("origin/".count))
    }
}
