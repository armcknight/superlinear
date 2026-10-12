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
}
