import Foundation
import Testing
@testable import superlinear

@Suite("WorktreeCleaner")
struct WorktreeCleanerTests {
    // The main checkout is listed first and must never be swept; a detached
    // worktree has no branch for `work clean` to name.
    @Test("Linked worktrees are read from git's porcelain listing, main checkout left out")
    func parsesPorcelain() {
        let porcelain = """
        worktree /repo
        HEAD 0655dc4
        branch refs/heads/main

        worktree /repo/worktrees/linear/mtg-10-diff
        HEAD db3ab76
        branch refs/heads/linear/mtg-10-diff

        worktree /repo/worktrees/detached
        HEAD 1234567
        detached

        """
        #expect(WorktreeCleaner.linkedWorktrees(porcelain) == [
            .init(path: "/repo/worktrees/linear/mtg-10-diff", branch: "linear/mtg-10-diff"),
            .init(path: "/repo/worktrees/detached", branch: nil),
        ])
        #expect(WorktreeCleaner.linkedWorktrees("worktree /repo\nHEAD 1\nbranch refs/heads/main\n").isEmpty)
    }

    // `work finish` deletes ignored files before it finds changes, so the
    // sweep must see them first; ignored files alone are not changes.
    @Test("A worktree with an edit or an untracked file has changes; one with only ignored files does not")
    func changes() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: repo) }
        func git(_ arguments: String...) { _ = Git.run(Array(arguments), in: repo) }
        git("init", "-q")
        git("config", "user.email", "t@t")
        git("config", "user.name", "t")
        try "a\n".write(toFile: "\(repo)/a.txt", atomically: true, encoding: .utf8)
        try ".env\n".write(toFile: "\(repo)/.gitignore", atomically: true, encoding: .utf8)
        git("add", ".")
        git("commit", "-q", "-m", "c")
        #expect(!WorktreeCleaner.hasChanges(worktree: repo))

        try "KEY=1\n".write(toFile: "\(repo)/.env", atomically: true, encoding: .utf8)
        #expect(!WorktreeCleaner.hasChanges(worktree: repo))

        try "b\n".write(toFile: "\(repo)/b.txt", atomically: true, encoding: .utf8)
        #expect(WorktreeCleaner.hasChanges(worktree: repo))
        try FileManager.default.removeItem(atPath: "\(repo)/b.txt")

        try "changed\n".write(toFile: "\(repo)/a.txt", atomically: true, encoding: .utf8)
        #expect(WorktreeCleaner.hasChanges(worktree: repo))

        #expect(WorktreeCleaner.hasChanges(worktree: "\(repo)/missing"))
    }
}
