import Foundation
import Testing
@testable import superlinear

// A branch listed as stale invites `work finish`, which deletes it, so none
// that is still needed may be listed, and what removal would lose is shown.
@Suite("Stale branches")
struct StaleBranchesTests {
    private let root = "/repo/worktrees"

    private func branch(_ name: String, worktree: Bool = true) -> StaleBranches.LocalBranch {
        StaleBranches.LocalBranch(
            name: name, lastCommit: Date(timeIntervalSince1970: 0), worktree: worktree ? "\(root)/\(name)" : nil)
    }

    private func pullRequest(_ number: Int, _ branch: String, _ state: PullRequest.State) -> PullRequest {
        PullRequest(number: number, url: "u\(number)", state: state, headRefName: branch, headRefOid: "sha\(number)")
    }

    @Test("Merged and closed pull requests make a branch stale, open ones and runs in flight do not")
    func reasons() {
        let stale = StaleBranches.find(
            branches: [
                branch("open"), branch("merged"), branch("closed"), branch("running"), branch("main"),
                branch("bare", worktree: false), branch("orphan"),
            ],
            pullRequests: [
                pullRequest(1, "open", .open), pullRequest(2, "merged", .merged), pullRequest(3, "closed", .closed),
                pullRequest(4, "running", .merged),
            ],
            protected: ["main"], inFlight: ["running"], worktreesRoot: root
        )
        #expect(stale.map(\.branch) == ["merged", "closed", "orphan"])
        #expect(stale.map(\.reason) == [.merged(2), .closed(3), .noPullRequest])
        #expect(stale.map(\.pullRequestHead) == ["sha2", "sha3", nil])
    }

    // A branch of your own, without a worktree work made, is left alone.
    @Test("A branch without a pull request is stale only with a worktree under worktrees/")
    func ownBranches() {
        let outside = StaleBranches.LocalBranch(name: "mine", lastCommit: nil, worktree: "/elsewhere/mine")
        let stale = StaleBranches.find(
            branches: [outside, branch("bare", worktree: false)], pullRequests: [], protected: [], inFlight: [],
            worktreesRoot: root
        )
        #expect(stale.isEmpty)
    }

    @Test("Worktrees are matched to their branches from git's porcelain listing")
    func worktreeListing() {
        let porcelain = """
        worktree /repo
        HEAD abc
        branch refs/heads/main

        worktree /repo/worktrees/linear/a-1
        HEAD def
        branch refs/heads/linear/a-1

        worktree /repo/worktrees/detached
        HEAD 123
        detached
        """
        #expect(StaleBranches.worktreeBranches(porcelain) == ["main": "/repo", "linear/a-1": "/repo/worktrees/linear/a-1"])
    }

    @Test("The detail gives the reason, the worktree, the last commit's age and what would be lost")
    func detail() {
        let now = Date(timeIntervalSince1970: 10 * 86_400)
        let merged = StaleBranch(branch: "b", reason: .merged(4), hasWorktree: true, lastCommit: Date(timeIntervalSince1970: 0), unpushedCommits: 0)
        #expect(merged.detail(now: now) == "merged in #4 · worktree · last commit 10d ago")
        let closed = StaleBranch(branch: "b", reason: .closed(5), hasWorktree: false, lastCommit: now, unpushedCommits: 1)
        #expect(closed.detail(now: now) == "#5 closed without a merge · last commit today · 1 unpushed commit")
        let none = StaleBranch(branch: "b", reason: .noPullRequest, hasWorktree: true, lastCommit: nil, unpushedCommits: 3)
        #expect(none.detail(now: now) == "no pull request · worktree · 3 unpushed commits")
    }

    @Test("Stale branches get their own section, after the tasks")
    func rendering() {
        let now = Date(timeIntervalSince1970: 86_400)
        var report = WorkspaceReport(
            name: "w", entries: [TaskEntry(identifier: "SL-1", title: "One", category: .completed, detail: nil)],
            warnings: []
        )
        report.stale = [StaleBranch(branch: "linear/sl-2", reason: .merged(2), hasWorktree: true, lastCommit: now, unpushedCommits: 0)]
        #expect(report.rendered(now: now) == """
        w
          Completed
            SL-1  One
          Stale branches and worktrees
            linear/sl-2
              merged in #2 · worktree · last commit today
        """)
    }
}
