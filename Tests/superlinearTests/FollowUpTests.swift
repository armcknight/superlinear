import Foundation
import Testing
@testable import superlinear

/// Linear with no open issues, for screening new issues; nothing is written.
private struct EmptyLinear: LinearWriting {
    func editableIssue(id: LinearIssue.ID) async throws -> EditableIssue { throw LinearClientError.invalidResponse }
    func openIssues(like title: String, teamId: LinearTeam.ID) async throws -> [IssueMatch] { [] }
    func labelId(named name: String, teamId: LinearTeam.ID) async throws -> LinearLabel.ID { "label" }
    func createIssue(
        teamId: LinearTeam.ID, projectId: LinearProject.ID?, title: String, description: String, labelIds: [LinearLabel.ID]
    ) async throws -> JSONValue { .null }
    func updateIssueDescription(id: LinearIssue.ID, description: String) async throws -> JSONValue { .null }
    func closeIssue(id: LinearIssue.ID) async throws -> JSONValue { .null }
    func promoteIssue(id: LinearIssue.ID) async throws -> JSONValue { .null }
    func createRelation(issueId: LinearIssue.ID, relatedIssueId: LinearIssue.ID, type: String) async throws -> JSONValue { .null }
    func spec(of target: ProposalTarget) async throws -> SpecText { throw LinearClientError.invalidResponse }
    func updateSpec(of target: ProposalTarget, content: String) async throws -> JSONValue { .null }
    func postProjectUpdate(projectId: LinearProject.ID, body: String) async throws -> JSONValue { .null }
}

private func data(_ text: String) -> Data { Data(text.utf8) }

private let entry = FollowUp(
    title: "Status crashes on an empty state file", description: "It force-unwraps the poll.", kind: .bug,
    evidence: "Sources/superlinear/Status.swift:42", relatedIssue: "SPL-4"
)

@Suite("Follow-ups file")
struct FollowUpFileTests {
    @Test("A valid file gives its entries")
    func valid() {
        let contents = FollowUpFile.parse(data("""
            [
              {"title": "Status crashes on an empty state file", "description": "It force-unwraps the poll.",
               "kind": "bug", "evidence": "Sources/superlinear/Status.swift:42", "relatedIssue": "SPL-4"},
              {"title": "Test the queue order", "description": "No test covers ties.", "kind": "test",
               "evidence": "swift test --filter queueOrder"}
            ]
            """))
        guard case .entries(let entries) = contents else {
            Issue.record("Expected entries, got \(contents)")
            return
        }
        #expect(entries.count == 2)
        #expect(entries[0] == entry)
        #expect(entries[1].kind == .test)
        #expect(entries[1].relatedIssue == nil)
    }

    @Test("An empty file, or an empty array, has no entries")
    func empty() {
        #expect(FollowUpFile.parse(Data()) == .none)
        #expect(FollowUpFile.parse(data(" \n")) == .none)
        #expect(FollowUpFile.parse(data("[]")) == .none)
    }

    @Test("A malformed file says what is wrong with it", arguments: [
        ("{\"title\": \"x\"}", "the file"),
        ("[{\"title\": \"x\", \"description\": \"y\", \"kind\": \"bug\"}]", "entry 1 has no evidence"),
        ("[{\"title\": \"x\", \"description\": \"y\", \"kind\": \"feature\", \"evidence\": \"z\"}]", "entry 1.kind"),
        ("[{\"title\": \" \", \"description\": \"y\", \"kind\": \"bug\", \"evidence\": \"\"}]", "entry 1 has no title or evidence"),
        ("not json", "the file"),
    ])
    func malformed(text: String, expected: String) {
        guard case .malformed(let reason) = FollowUpFile.parse(data(text)) else {
            Issue.record("Expected \(text) to be malformed")
            return
        }
        #expect(reason.contains(expected), "\(reason)")
    }

    @Test("A missing file has no entries; entries not proposed are kept, and none removes the file")
    func readAndKeep() throws {
        let worktree = FileManager.default.temporaryDirectory.appendingPathComponent("superlinear-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: worktree) }
        #expect(FollowUpFile.read(worktree: worktree) == .none)

        try FileManager.default.createDirectory(
            atPath: "\(worktree)/\(FollowUpFile.directory)", withIntermediateDirectories: true
        )
        try FollowUpFile.keep([entry], worktree: worktree)
        #expect(FollowUpFile.read(worktree: worktree) == .entries([entry]))

        try FollowUpFile.keep([], worktree: worktree)
        #expect(!FileManager.default.fileExists(atPath: FollowUpFile.path(worktree: worktree)))
    }

    @Test("The directory is added to git's exclude file once")
    func exclude() {
        #expect(FollowUpFile.excluding("") == "/.superlinear/\n")
        #expect(FollowUpFile.excluding("# git ls-files\n*.o") == "# git ls-files\n*.o\n/.superlinear/\n")
        #expect(FollowUpFile.excluding("*.o\n/.superlinear/\n") == nil)
        #expect(FollowUpFile.excluding(".superlinear/\n") == nil)
    }
}

@Suite("Follow-up proposals")
struct FollowUpProposalTests {
    private let source = ProposalSource(
        kind: .agentSession, value: "abc", issue: "SPL-12", pullRequest: "https://github.com/o/r/pull/7"
    )

    @Test("A follow-up becomes a new issue in the agent's team, related to its issue")
    func draft() {
        let draft = entry.draft(teamId: "team", relatedIssueId: "i4", agentIssue: "SPL-12", source: source)
        guard case .createIssue(let teamId, let projectId, let title, let description, let related) = draft.payload else {
            Issue.record("Expected a new issue, got \(draft.payload)")
            return
        }
        #expect(teamId == "team")
        #expect(projectId == nil)
        #expect(title == entry.title)
        #expect(related == "i4")
        #expect(description.contains("It force-unwraps the poll."))
        #expect(description.contains("Kind: bug"))
        #expect(description.contains("Sources/superlinear/Status.swift:42"))
        #expect(description.contains("Related to SPL-4."))
        #expect(description.contains("Found by the agent working on SPL-12."))
        #expect(draft.target == .team("team"))
        #expect(draft.source == source)
    }

    @Test("The source names the agent's session, issue and pull request")
    func sourceLinks() throws {
        #expect(source.line == "Source: agent session abc for SPL-12, https://github.com/o/r/pull/7")
        let bare = ProposalSource(kind: .agentSession, value: "abc")
        #expect(bare.line == "Source: agent session abc")
        let pullRequest = ProposalSource(kind: .pullRequest, value: "https://github.com/o/r/pull/7", issue: "SPL-12")
        #expect(pullRequest.line == "Source: https://github.com/o/r/pull/7 for SPL-12")

        // Kept in the state file.
        let decoded = try JSONDecoder().decode(ProposalSource.self, from: JSONEncoder().encode(source))
        #expect(decoded == source)
        let old = try JSONDecoder().decode(ProposalSource.self, from: data(#"{"kind": "agentSession", "value": "abc"}"#))
        #expect(old == bare)
    }

    @Test("Every agent prompt asks for follow-ups in the file")
    func prompts() {
        let run = AgentRun(issueId: "id-1", identifier: "SL-1", branchName: "me/sl-1-fix", sessionId: "abc")
        var review = run
        review.review = ReviewRequest(number: 12, url: "https://github.com/o/r/pull/12")
        var conflict = run
        conflict.conflict = ConflictRequest(
            number: 12, url: "https://github.com/o/r/pull/12", baseBranch: "main",
            attempt: ConflictAttempt(head: "h", base: "b")
        )
        for run in [run, review, conflict] {
            let prompt = AgentRunner.prompt(for: run)
            #expect(prompt.contains(".superlinear/followups.json"))
            #expect(prompt.contains("do not create Linear issues"))
            #expect(prompt.contains("`bug`, `task`, `test`, `spec`"))
            #expect(prompt.contains("`relatedIssue`"))
        }
    }
}

@Suite("Failing workflows")
struct WorkflowFailureTests {
    private func run(
        _ workflow: String, _ conclusion: WorkflowRun.Conclusion?, at seconds: TimeInterval, status: String = "completed"
    ) -> WorkflowRun {
        WorkflowRun(
            headBranch: "main", status: status, startedAt: nil, updatedAt: nil, workflowName: workflow,
            conclusion: conclusion, url: "https://github.com/o/r/actions/runs/\(Int(seconds))", headSha: "abcdef0123456789",
            createdAt: Date(timeIntervalSince1970: seconds)
        )
    }

    @Test("Each workflow counts by its latest completed run")
    func failing() {
        let runs = [
            run("CI", .failure, at: 1), run("CI", .failure, at: 3), run("CI", .success, at: 2),
            run("CI", nil, at: 4, status: "in_progress"),
            run("Lint", .failure, at: 1), run("Lint", .success, at: 2),
            run("Release", .timedOut, at: 5),
        ]
        #expect(WorkflowFailures.failing(runs).map(\.url) == [
            "https://github.com/o/r/actions/runs/3", "https://github.com/o/r/actions/runs/5",
        ])
    }

    @Test("Repeated failures of one workflow make one proposal")
    func oneProposal() async throws {
        let engine = ProposalEngine(
            workspace: "w", autonomy: Autonomy(), linear: EmptyLinear(),
            audit: AuditLog(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        )
        let first = WorkflowFailures.draft(run("CI", .failure, at: 1), branch: "main", teamId: "team")
        guard case .store(let proposal, _) = try await engine.screen(first, existing: []) else {
            Issue.record("Expected the first failure to be proposed")
            return
        }
        #expect(proposal.source == ProposalSource(kind: .workflowRun, value: "https://github.com/o/r/actions/runs/1"))
        #expect(proposal.source.line == "Source: https://github.com/o/r/actions/runs/1")
        guard case .createIssue(_, _, let title, let description, _) = proposal.payload else {
            Issue.record("Expected a new issue")
            return
        }
        #expect(title == "CI fails on main: CI")
        #expect(description.contains("abcdef012345"))

        let second = WorkflowFailures.draft(run("CI", .failure, at: 2), branch: "main", teamId: "team")
        #expect(try await engine.screen(second, existing: [proposal]) == .skip(reason: "The same createIssue is pending already"))
        let other = WorkflowFailures.draft(run("Lint", .failure, at: 2), branch: "main", teamId: "team")
        guard case .store = try await engine.screen(other, existing: [proposal]) else {
            Issue.record("Expected another workflow to be proposed")
            return
        }
    }

    @Test("Runs decode from gh's JSON")
    func decode() throws {
        let runs = try WorkflowFailures.decodeRuns(data("""
            [{"headBranch": "main", "workflowName": "CI", "status": "completed", "conclusion": "failure",
              "url": "https://github.com/o/r/actions/runs/1", "headSha": "abc", "createdAt": "2026-10-16T12:00:00Z"},
             {"headBranch": "main", "workflowName": "CI", "status": "in_progress", "conclusion": ""},
             {"headBranch": "main", "workflowName": "CI", "status": "completed", "conclusion": "brand_new"}]
            """))
        #expect(runs.map(\.conclusion) == [.failure, nil, .unknown])
        #expect(runs.first?.workflowName == "CI")
        #expect(runs.first?.createdAt == ISO8601DateFormatter().date(from: "2026-10-16T12:00:00Z"))
    }
}

@Suite("Added TODOs")
struct AddedTodoTests {
    private let diff = """
        diff --git a/Sources/A.swift b/Sources/A.swift
        index 1111111..2222222 100644
        --- a/Sources/A.swift
        +++ b/Sources/A.swift
        @@ -10,4 +10,6 @@ struct A {
             let a = 1
        -    // TODO: old one, removed
        +    // TODO: handle the empty case
        +    let b = 2
             let c = 3
        +    // FIXME(SPL-24): already tracked
        +    // FIXME
        diff --git a/Sources/B.swift b/Sources/B.swift
        new file mode 100644
        --- /dev/null
        +++ b/Sources/B.swift
        @@ -0,0 +1,2 @@
        +// A TODOS list is not a marker
        +/* TODO - split this file */
        """

    @Test("Added lines with a marker are found at their new line numbers")
    func parse() {
        #expect(AddedTodos.parse(diff: diff) == [
            .init(file: "Sources/A.swift", line: 11, marker: .todo, text: "// TODO: handle the empty case"),
            .init(file: "Sources/A.swift", line: 15, marker: .fixme, text: "// FIXME"),
            .init(file: "Sources/B.swift", line: 2, marker: .todo, text: "/* TODO - split this file */"),
        ])
    }

    @Test("A TODO's words make the title, and the pull request is its source")
    func draft() {
        let todos = AddedTodos.parse(diff: diff)
        #expect(AddedTodos.title(todos[0]) == "TODO in A.swift: handle the empty case")
        #expect(AddedTodos.title(todos[1]) == "Resolve the FIXME in A.swift")
        #expect(AddedTodos.title(todos[2]) == "TODO in B.swift: split this file")

        let pullRequest = PullRequest(number: 7, url: "https://github.com/o/r/pull/7", state: .merged)
        let draft = AddedTodos.draft(todos[0], pullRequest: pullRequest, agentIssue: "SPL-12", issueId: "i12", teamId: "team")
        #expect(draft.source == ProposalSource(kind: .pullRequest, value: pullRequest.url, issue: "SPL-12"))
        guard case .createIssue(let teamId, _, _, let description, let related) = draft.payload else {
            Issue.record("Expected a new issue")
            return
        }
        #expect(teamId == "team")
        #expect(related == "i12")
        #expect(description.contains("`Sources/A.swift:11`"))
    }

    @Test("A long title is cut short")
    func longTitle() {
        let todo = AddedTodos.Todo(file: "A.swift", line: 1, marker: .todo, text: "// TODO: " + String(repeating: "x", count: 200))
        #expect(AddedTodos.title(todo).count == AddedTodos.maxTitleLength)
    }
}
