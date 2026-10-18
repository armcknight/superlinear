import Foundation
import Testing
@testable import superlinear

/// Linear as the planning job reads it, and as proposals write to it, kept in
/// memory, recording every write.
private actor FakeLinear: PlanningReading, LinearWriting {
    var issues: [PlanningIssue]
    var projects: [PlanningProject]
    var teams: [PlanningTeam]
    var specs: [String: SpecText]
    var completed: [Completion] = []
    var writes: [String] = []

    struct Completion {
        var identifier: LinearIssue.Identifier
        var at: Date
    }

    init(issues: [PlanningIssue], projects: [PlanningProject] = [], teams: [PlanningTeam], specs: [String: SpecText] = [:]) {
        self.issues = issues
        self.projects = projects
        self.teams = teams
        self.specs = specs
    }

    func complete(_ identifier: LinearIssue.Identifier, at: Date) {
        completed.append(Completion(identifier: identifier, at: at))
    }

    func planningIssues(teamIds: [LinearTeam.ID]) async throws -> [PlanningIssue] { issues }
    func planningProjects(ids: [LinearProject.ID]) async throws -> [PlanningProject] { projects.filter { ids.contains($0.id) } }
    func planningTeams(ids: [LinearTeam.ID]) async throws -> [PlanningTeam] { teams }

    func completedIssues(teamIds: [LinearTeam.ID], after: Date) async throws -> [LinearIssue.Identifier] {
        completed.filter { $0.at > after }.sorted { $0.at < $1.at }.map(\.identifier)
    }

    func spec(of target: ProposalTarget) async throws -> SpecText {
        guard let spec = specs[target.rawID] else { throw LinearClientError.apiError(["Entity not found"]) }
        return spec
    }

    private func written(_ description: String) -> JSONValue {
        writes.append(description)
        return .object(["success": .bool(true)])
    }

    func editableIssue(id: LinearIssue.ID) async throws -> EditableIssue {
        guard let issue = issues.first(where: { $0.id == id }) else { throw LinearClientError.apiError(["Entity not found"]) }
        return EditableIssue(
            id: issue.id, identifier: issue.identifier.rawValue, description: issue.description, updatedAt: issue.updatedAt,
            labels: issue.labels.map(\.rawValue), stateType: issue.stateType, teamId: issue.teamId)
    }

    func openIssues(like title: String, teamId: LinearTeam.ID) async throws -> [IssueMatch] { [] }
    func labelId(named name: String, teamId: LinearTeam.ID) async throws -> LinearLabel.ID { "label" }

    func createIssue(
        teamId: LinearTeam.ID, projectId: LinearProject.ID?, title: String, description: String,
        labelIds: [LinearLabel.ID], stateId: LinearState.ID?
    ) async throws -> CreatedIssue {
        CreatedIssue(id: "new", identifier: "NEW-1", url: nil, response: written("create \(title) in \(teamId) project=\(projectId?.rawValue ?? "none")"))
    }

    func updateIssueDescription(id: LinearIssue.ID, description: String) async throws -> JSONValue {
        written("edit \(id) to \(description)")
    }

    func closeIssue(id: LinearIssue.ID) async throws -> JSONValue { written("close \(id)") }
    func promoteIssue(id: LinearIssue.ID) async throws -> JSONValue { written("promote \(id)") }

    func createRelation(issueId: LinearIssue.ID, relatedIssueId: LinearIssue.ID, type: String) async throws -> JSONValue {
        written("relate \(issueId) \(type) \(relatedIssueId)")
    }

    func updateSpec(of target: ProposalTarget, content: String) async throws -> JSONValue {
        written("spec \(target.rawID) to \(content)")
    }

    func postProjectUpdate(projectId: LinearProject.ID, body: String) async throws -> JSONValue {
        written("update \(projectId)")
    }
}

private let updated = Date(timeIntervalSince1970: 1_700_000_000)
private let team = PlanningTeam(id: "team-1", key: "SPL", name: "Superlinear")
private let project = PlanningProject(
    id: "project-1", name: "Planning", content: "Exit criteria: a daily job.", updatedAt: updated,
    milestones: [.init(name: "Beta")])

private func issue(
    _ number: Int, state: LinearStateType = .unstarted, description: String = "", labels: [String] = [],
    relations: [PlanningRelation] = [], project: PlanningProject? = nil
) -> PlanningIssue {
    PlanningIssue(
        id: LinearIssue.ID(rawValue: "issue-\(number)"), identifier: LinearIssue.Identifier(rawValue: "SPL-\(number)"),
        title: "Issue \(number)", description: description, stateName: state == .backlog ? "Backlog" : "Todo",
        stateType: state, priority: 2, teamId: team.id, teamKey: team.key, projectId: project?.id,
        projectName: project?.name, milestone: nil, labels: labels.map { LinearLabel.Name(rawValue: $0) }, relations: relations,
        updatedAt: updated)
}

private let issues = [
    issue(1, description: "Mine.\n\n<!-- superlinear -->\nOld notes\n<!-- /superlinear -->", project: project),
    issue(2, state: .backlog, relations: [PlanningRelation(type: .blocks, identifier: "SPL-3", direction: .incoming)]),
    issue(3),
    issue(4, labels: ["superlinear: hands off"]),
    issue(5, description: "All superlinear's.", labels: ["superlinear"]),
]

private let mergedCommit = PlanningCommit(
    sha: "aaaaaaa1111111111111111111111111111111111", author: "A", date: updated, subject: "feat: done (#7)", body: "",
    pullRequest: PlanningPullRequest(number: 7, title: "feat: done", url: "https://github.com/o/r/pull/7", headRefName: "linear/spl-3-x"),
    issues: ["SPL-3"])
private let directCommit = PlanningCommit(
    sha: "bbbbbbb2222222222222222222222222222222222", author: "A", date: updated, subject: "chore: tidy", body: "")

private func context(commits: [PlanningCommit] = [mergedCommit, directCommit]) -> PlanningContext {
    PlanningContext(
        workspace: "w", trigger: "a test asked", defaultBranch: "main", worktreePath: "/repo",
        head: "ccccccc3333333333333333333333333333333333", since: "0000000444444444444444444444444444444444",
        commits: commits, completedIssues: ["SPL-7"], issues: issues, projects: [project], teams: [team],
        spec: PlanningSpec(id: "spec0123", url: "https://linear.app/t/document/spec-spec0123", content: "Spec v1", updatedAt: updated))
}

private func item(_ kind: String, _ fill: (inout PlanningOutput.Item) -> Void = { _ in }) -> PlanningOutput.Item {
    var item = PlanningOutput.Item(kind: kind)
    item.reason = "because"
    fill(&item)
    return item
}

private func ingest(_ items: [PlanningOutput.Item], context: PlanningContext = context()) -> PlanningIngest {
    PlanningIngest(PlanningOutput(proposals: items), context: context, sessionId: "session-1")
}

private func scratch() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("superlinear-\(UUID().uuidString)")
}

private func workspace(_ extra: String = "", repoPath: String = "/repo") throws -> WorkspaceConfig {
    let json = #"{"workspaces": [{"name": "w", "apiKey": "k", "repoPath": ""# + repoPath + #"""# + extra + "}]}"
    return try Config.decoded(from: Data(json.utf8)).workspaces[0]
}

private func record(
    _ session: ClaudeSession.ID, startedAt: Date, endedAt: Date, head: GitCommit.SHA?, error: String? = nil
) -> PlanningRunRecord {
    PlanningRunRecord(sessionId: session, startedAt: startedAt, endedAt: endedAt, head: head, error: error)
}

@Suite("Planning")
struct PlanningTests {
    // MARK: Config and schedule

    @Test("Planning is off unless enabled")
    func config() throws {
        #expect(try workspace().planning.enabled == false)
        #expect(try workspace(#", "planning": {"specDocumentURL": "https://linear.app/t/document/spec-ab12"}"#).planning.enabled == false)
        let on = try workspace(#", "planning": {"enabled": true}"#)
        #expect(on.planning.enabled)
        #expect(on.planning.specDocumentURL == nil)
    }

    @Test("The next job starts from the last successful head, polls compare against the last head, and 30 jobs are kept")
    func history() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func run(hoursAgo: Double, error: String? = nil, head: GitCommit.SHA? = "h\(Int.random(in: 0..<1000))") -> PlanningRunRecord {
            record("s", startedAt: now.addingTimeInterval(-hoursAgo * 3600), endedAt: now.addingTimeInterval(-hoursAgo * 3600), head: head, error: error)
        }
        let good = run(hoursAgo: 48, head: "good")
        let failed = run(hoursAgo: 24, error: "boom", head: "failed")
        #expect(PlanningHistory.since([good, failed]) == "good")
        #expect(PlanningHistory.last([good, failed]) == failed)
        #expect(PlanningHistory.lastHead([good, failed]) == "failed")
        // A job that never launched has no head; the branch is compared against the last that did.
        #expect(PlanningHistory.lastHead([good, run(hoursAgo: 1, error: "no claude", head: nil)]) == "good")

        let many = (0..<40).map { run(hoursAgo: Double($0)) }
        let kept = PlanningHistory.appending(run(hoursAgo: 0), to: many)
        #expect(kept.count == PlanningHistory.retainedRuns)
        #expect(kept.last?.startedAt == now)
    }

    @Test("A job is due for a workspace's first, when the default branch moves, and when issues are completed")
    func trigger() async throws {
        let repo = try FixtureRepository()
        defer { repo.remove() }
        let first = try repo.commit("one")
        let linear = FakeLinear(issues: issues, teams: [team])
        let gatherer = PlanningGatherer(workspace: try workspace(#", "planning": {"enabled": true}"#, repoPath: repo.path), linear: linear)
        let now = Date()

        #expect(try await gatherer.trigger(history: []) == .firstJob)
        let ran = record("s", startedAt: now.addingTimeInterval(-3600), endedAt: now.addingTimeInterval(-3000), head: first)
        #expect(try await gatherer.trigger(history: [ran]) == nil)

        let second = try repo.commit("two")
        #expect(try await gatherer.trigger(history: [ran]) == .newCommits(second))
        // A failed job's head counts: the branch has to move again.
        let failed = record("t", startedAt: now.addingTimeInterval(-600), endedAt: now.addingTimeInterval(-500), head: second, error: "boom")
        #expect(try await gatherer.trigger(history: [ran, failed]) == nil)

        // Completions before the last job ended were its to see.
        await linear.complete("SPL-8", at: now.addingTimeInterval(-550))
        #expect(try await gatherer.trigger(history: [ran, failed]) == nil)
        await linear.complete("SPL-9", at: now.addingTimeInterval(-400))
        await linear.complete("SPL-10", at: now.addingTimeInterval(-300))
        let trigger = try await gatherer.trigger(history: [ran, failed])
        #expect(trigger == .completedIssues(["SPL-9", "SPL-10"]))
        #expect(trigger?.description == "SPL-9 and SPL-10 were completed")
        #expect(PlanningTrigger.completedIssues(["SPL-9"]).description == "SPL-9 was completed")
        #expect(PlanningTrigger.newCommits(second).description == "the default branch moved to \(second.rawValue.prefix(7))")

        // Without a default branch, the check fails rather than answering.
        let empty = scratch()
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let elsewhere = PlanningGatherer(workspace: try workspace(repoPath: empty.path), linear: linear)
        await #expect(throws: PlanningError.self) { try await elsewhere.trigger(history: [ran]) }
    }

    @Test("`plan` takes a workspace and a config")
    func arguments() {
        #expect(Command.parse(["plan"]) == .plan(configPath: nil, workspace: nil))
        #expect(Command.parse(["plan", "--workspace", "w", "--config", "c"]) == .plan(configPath: "c", workspace: "w"))
        #expect(Command.parse(["plan", "--print"]) == .invalid("unknown option for plan: --print"))
        #expect(Command.parse(["plan", "--workspace"]) == .invalid("--workspace needs a name"))
    }

    // MARK: The fixture repository

    @Test("The job finds the default branch's worktree and the commits since the last run")
    func fixtureRepository() async throws {
        let repo = try FixtureRepository()
        defer { repo.remove() }
        let first = try repo.commit("feat: start")
        try repo.commit("feat(planning): add the job (#7)", body: "Refs SPL-3 and UTF-8")
        let last = try repo.commit("fix: tidy")

        #expect(PlanningGit.defaultBranch(repoPath: repo.path) == "main")
        let worktree = try #require(PlanningGit.worktree(of: "main", repoPath: repo.path))
        #expect(URL(fileURLWithPath: worktree).resolvingSymlinksInPath() == URL(fileURLWithPath: repo.path).resolvingSymlinksInPath())
        #expect(PlanningGit.worktree(of: "other", repoPath: repo.path) == nil)
        #expect(PlanningGit.ref(of: "main", repoPath: repo.path) == "refs/heads/main")

        // With no remote, the head is the local branch's.
        #expect(PlanningGit.head(of: "main", repoPath: repo.path) == last)

        let all = PlanningGit.commits(repoPath: repo.path, since: nil, through: "main", notBefore: Date().addingTimeInterval(-3600))
        #expect(all.map(\.subject) == ["fix: tidy", "feat(planning): add the job (#7)", "feat: start"])
        let later = PlanningGit.commits(repoPath: repo.path, since: first, through: "main", notBefore: .distantFuture)
        #expect(later.map(\.sha.rawValue.count) == [40, 40])
        #expect(later.first?.sha == last)
        #expect(later.last?.body == "Refs SPL-3 and UTF-8")
        // A head git no longer has falls back to the time.
        let unknown = PlanningGit.commits(
            repoPath: repo.path, since: GitCommit.SHA(rawValue: String(repeating: "0", count: 40)), through: "main",
            notBefore: Date().addingTimeInterval(3600))
        #expect(unknown.isEmpty)

        let linear = FakeLinear(issues: issues, projects: [project], teams: [team], specs: ["spec0123": SpecText(content: "Spec v1", updatedAt: updated)])
        let config = try workspace(#", "planning": {"enabled": true, "specDocumentURL": "https://linear.app/t/document/spec-spec0123"}"#, repoPath: repo.path)
        let merged = try #require(later.last)
        var gatherer = PlanningGatherer(workspace: config, linear: linear)
        gatherer.fetch = false
        gatherer.mergedPullRequests = { base, _ in
            #expect(base == "main")
            return [MergedPullRequest(
                number: 7, title: "Add the job", url: "https://github.com/o/r/pull/7", headRefName: "linear/spl-2-add-the-job",
                mergeCommit: .init(oid: merged.sha))]
        }
        let now = Date()
        let previous = record("s", startedAt: now.addingTimeInterval(-7200), endedAt: now.addingTimeInterval(-3600), head: first)
        await linear.complete("SPL-6", at: now.addingTimeInterval(-7000))
        await linear.complete("SPL-7", at: now.addingTimeInterval(-1800))
        let gathered = try await gatherer.gather(history: [previous], trigger: .newCommits(last), now: now)
        #expect(gathered.trigger == "the default branch moved to \(last.rawValue.prefix(7))")
        #expect(gathered.defaultBranch == "main")
        #expect(gathered.head == last)
        #expect(gathered.since == first)
        #expect(gathered.completedIssues == ["SPL-7"])
        #expect(gathered.commits.count == 2)
        #expect(gathered.commits.last?.pullRequest?.number == 7)
        // From the branch first, then the body; UTF-8 is no team's.
        #expect(gathered.commits.last?.issues == ["SPL-2", "SPL-3"])
        #expect(gathered.commits.first?.issues == [])
        #expect(gathered.issues.count == issues.count)
        #expect(gathered.projects == [project])
        #expect(gathered.spec?.content == "Spec v1")
        #expect(gathered.range == "\(first.short)..\(last.short)")
        // The first job looks back a day for commits and completions alike.
        let fresh = try await gatherer.gather(history: [], trigger: .firstJob, now: now)
        #expect(fresh.since == nil)
        #expect(fresh.commits.count == 3)
        #expect(fresh.completedIssues == ["SPL-6", "SPL-7"])
    }

    @Test("A worktree with the default branch behind is fast-forwarded when clean")
    func fastForward() throws {
        let repo = try FixtureRepository()
        defer { repo.remove() }
        try repo.commit("one")
        let worktree = repo.path + "-wt"
        defer { try? FileManager.default.removeItem(atPath: worktree) }
        #expect(Git.run(["worktree", "add", "--quiet", "--detach", worktree], in: repo.path) != nil)
        let ahead = try repo.commit("two")
        #expect(PlanningGit.fastForward(worktree: worktree, to: "refs/heads/main") == nil)
        #expect(Git.run(["rev-parse", "HEAD"], in: worktree) == ahead.rawValue)
        try repo.commit("three")
        try "dirty".write(toFile: worktree + "/file", atomically: true, encoding: .utf8)
        #expect(PlanningGit.fastForward(worktree: worktree, to: "refs/heads/main")?.contains("uncommitted") == true)
    }

    // MARK: The prompt and the session

    @Test("The prompt gives the commits, issues, projects and spec, and where to write")
    func prompt() {
        let text = PlanningPrompt.render(context(), outputPath: "/runs/out.json")
        #expect(text.contains("/runs/out.json"))
        #expect(text.contains("because a test asked"))
        #expect(text.contains("aaaaaaa feat: done (#7)"))
        #expect(text.contains("## Issues completed since the last job\n\nSPL-7."))
        #expect(text.contains("https://github.com/o/r/pull/7"))
        #expect(text.contains("### SPL-2: Issue 2"))
        #expect(text.contains("blocked by SPL-3"))
        #expect(text.contains("Current managed block: \nOld notes"))
        #expect(text.contains("Exit criteria: a daily job."))
        #expect(text.contains("Milestones: Beta"))
        #expect(text.contains("## Spec document"))
        for kind in PlanningPrompt.kinds { #expect(text.contains(kind.rawValue)) }
    }

    @Test("A new session gets its ID; an interrupted one is resumed")
    func claudeArguments() {
        let start = PlanningRunner.claudeArguments(sessionId: "s1", mode: .start, runsDirectory: "/runs")
        #expect(start == ["claude", "-p", "--session-id", "s1", "--allowedTools", PlanningRunner.allowedTools, "--add-dir", "/runs"])
        #expect(PlanningRunner.claudeArguments(sessionId: "s1", mode: .resume, runsDirectory: "/runs").contains("--resume"))
    }

    @Test("A finished job's proposals are read back against its context; a failed one records why")
    func finish() throws {
        let home = scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = PlanningRunner(home: home.path, environment: [:])
        let run = PlanningRun(sessionId: "s1", startedAt: updated, worktreePath: "/repo")
        try runner.prepare(context(), sessionId: run.sessionId)
        #expect(FileManager.default.fileExists(atPath: runner.promptFile("s1")))
        try Data(#"{"proposals": [{"kind": "closeIssue", "issue": "spl-3", "reason": "Done in #7", "pullRequest": 7}, {"kind": "closeIssue", "issue": "SPL-99", "reason": "x"}]}"#.utf8)
            .write(to: URL(fileURLWithPath: runner.outputFile("s1")))
        let job = PlanningJob(workspace: try workspace(), runner: runner)

        let (record, ingest) = job.finish(run, status: 0, now: updated)
        #expect(record.error == nil)
        #expect(record.head == context().head)
        #expect(record.skipped == 1)
        #expect(ingest.drafts.count == 1)
        #expect(ingest.drafts.first?.source == ProposalSource(kind: .pullRequest, value: "https://github.com/o/r/pull/7"))

        let (failed, nothing) = job.finish(run, status: 1, now: updated)
        #expect(failed.error?.contains("exited 1") == true)
        #expect(nothing.drafts.isEmpty)

        try FileManager.default.removeItem(atPath: runner.outputFile("s1"))
        #expect(job.finish(run, status: 0, now: updated).0.error?.contains("no proposals file") == true)
        runner.cleanUp("s1")
        #expect(!FileManager.default.fileExists(atPath: runner.contextFile("s1")))
    }

    // MARK: Each kind of proposal

    @Test("closeIssue: an open issue, with the commit as its source")
    func closeIssue() throws {
        let result = ingest([
            item("closeIssue") { $0.issue = "SPL-3"; $0.commit = "aaaaaaa1" },
            item("closeIssue") { $0.issue = "SPL-1"; $0.commit = "bbbbbbb" },
            item("closeIssue") { $0.issue = "SPL-1" },
        ])
        #expect(result.refused.isEmpty)
        let draft = try #require(result.drafts.first)
        #expect(draft.payload == .closeIssue)
        #expect(draft.target == .issue("issue-3", name: "SPL-3"))
        #expect(draft.targetUpdatedAt == updated)
        #expect(draft.source == ProposalSource(kind: .pullRequest, value: "https://github.com/o/r/pull/7"))
        #expect(result.drafts[1].source == ProposalSource(kind: .commitRange, value: "bbbbbbb"))
        #expect(result.drafts[2].source == ProposalSource(kind: .commitRange, value: "0000000..ccccccc"))
        // With no commits, the session is the source.
        let quiet = ingest([item("closeIssue") { $0.issue = "SPL-1" }], context: context(commits: []))
        #expect(quiet.drafts.first?.source == ProposalSource(kind: .agentSession, value: "session-1"))
    }

    @Test("editIssue: the managed block of the owner's issue, the whole of superlinear's")
    func editIssue() {
        let result = ingest([
            item("editIssue") { $0.issue = "SPL-1"; $0.newText = "New notes" },
            item("editIssue") { $0.issue = "SPL-5"; $0.newText = "Rewritten." },
            item("editIssue") { $0.issue = "SPL-1"; $0.newText = "Old notes" },
            item("editIssue") { $0.issue = "SPL-1" },
        ])
        #expect(result.drafts.map(\.payload) == [
            .editIssue(oldText: "Old notes", newText: "New notes"),
            .editIssue(oldText: "All superlinear's.", newText: "Rewritten."),
        ])
        #expect(result.refused.count == 2)
    }

    @Test("addRelation: two open issues, not already related")
    func addRelation() {
        let result = ingest([
            item("addRelation") { $0.issue = "SPL-1"; $0.relatedIssue = "SPL-2"; $0.relationType = "blocks" },
            item("addRelation") { $0.issue = "SPL-3"; $0.relatedIssue = "SPL-2"; $0.relationType = "blocks" },
            item("addRelation") { $0.issue = "SPL-1"; $0.relatedIssue = "SPL-1"; $0.relationType = "related" },
            item("addRelation") { $0.issue = "SPL-1"; $0.relatedIssue = "SPL-3"; $0.relationType = "friends" },
        ])
        #expect(result.drafts.map(\.payload) == [.addRelation(relatedIssueId: "issue-2", type: "blocks")])
        #expect(result.drafts.first?.target == .issue("issue-1", name: "SPL-1"))
        #expect(result.refused.count == 3)
        #expect(result.refused[0].contains("exists already"))
    }

    @Test("createIssue: in a watched team, optionally in a project and following an issue")
    func createIssue() {
        let result = ingest([
            item("createIssue") {
                $0.team = "spl"; $0.project = "Planning"; $0.title = "Cover the exit criteria"; $0.description = "Do it."
                $0.relatedIssue = "SPL-1"
            },
            item("createIssue") { $0.team = "OTHER"; $0.title = "Elsewhere" },
            item("createIssue") { $0.team = "SPL" },
        ])
        #expect(result.drafts.map(\.payload) == [.createIssue(
            teamId: "team-1", projectId: "project-1", title: "Cover the exit criteria", description: "Do it.",
            relatedIssueId: "issue-1")])
        #expect(result.drafts.first?.target == .team("team-1", name: "SPL"))
        #expect(result.refused.count == 2)
    }

    @Test("changeSpec: the spec document or a project's description")
    func changeSpec() {
        let result = ingest([
            item("changeSpec") { $0.spec = "document"; $0.newText = "Spec v2" },
            item("changeSpec") { $0.spec = "project-1"; $0.newText = "Exit criteria: two jobs." },
            item("changeSpec") { $0.newText = "Spec v1" },
        ])
        #expect(result.drafts.map(\.payload) == [
            .changeSpec(oldText: "Spec v1", newText: "Spec v2"),
            .changeSpec(oldText: "Exit criteria: a daily job.", newText: "Exit criteria: two jobs."),
        ])
        #expect(result.drafts.map(\.target) == [.document("spec0123", name: "the spec"), .project("project-1", name: "Planning")])
        #expect(result.refused.count == 1)
        var noSpec = context()
        noSpec.spec = nil
        #expect(ingest([item("changeSpec") { $0.newText = "x" }], context: noSpec).refused.first?.contains("no spec document") == true)
    }

    @Test("promoteIssue: only a backlog issue")
    func promoteIssue() {
        let result = ingest([item("promoteIssue") { $0.issue = "SPL-2" }, item("promoteIssue") { $0.issue = "SPL-3" }])
        #expect(result.drafts.map(\.payload) == [.promoteIssue])
        #expect(result.refused.first?.contains("not in the backlog") == true)
    }

    @Test("Proposals without a reason, of other kinds, or on hands-off and unknown issues are refused")
    func refusals() {
        let result = ingest([
            item("closeIssue") { $0.issue = "SPL-4" },
            item("closeIssue") { $0.issue = "SPL-42" },
            item("closeIssue") { $0.issue = "SPL-1"; $0.reason = " " },
            item("postProjectUpdate"),
            item("deleteEverything"),
        ])
        #expect(result.drafts.isEmpty)
        #expect(result.refused.count == 5)
        #expect(result.refused[0].contains("hands off"))
    }

    @Test("The output names pull requests by number or URL")
    func outputDecoding() throws {
        let output = try PlanningOutput.decoded(from: Data(#"""
            {"proposals": [
              {"kind": "closeIssue", "issue": "SPL-3", "reason": "r", "pullRequest": 7},
              {"kind": "closeIssue", "issue": "SPL-3", "reason": "r", "pullRequest": "https://github.com/o/r/pull/7"},
              {"kind": "closeIssue", "issue": "SPL-3", "reason": "r", "pullRequest": "#7", "extra": true}
            ]}
            """#.utf8))
        let sources = ingest(output.proposals).drafts.map(\.source.value)
        #expect(sources == Array(repeating: "https://github.com/o/r/pull/7", count: 3))
    }

    @Test("Each kind goes through the proposal store and applies to Linear")
    func storeAndApply() async throws {
        let linear = FakeLinear(issues: issues, projects: [project], teams: [team], specs: [
            "spec0123": SpecText(content: "Spec v1", updatedAt: updated),
            "project-1": SpecText(content: project.content, updatedAt: updated),
        ])
        let result = ingest([
            item("closeIssue") { $0.issue = "SPL-3" },
            item("editIssue") { $0.issue = "SPL-1"; $0.newText = "New notes" },
            item("addRelation") { $0.issue = "SPL-1"; $0.relatedIssue = "SPL-3"; $0.relationType = "related" },
            item("createIssue") { $0.team = "SPL"; $0.title = "A gap" },
            item("changeSpec") { $0.newText = "Spec v2" },
            item("promoteIssue") { $0.issue = "SPL-2" },
        ])
        #expect(result.drafts.map(\.payload.kind) == PlanningPrompt.kinds)
        let audit = scratch()
        defer { try? FileManager.default.removeItem(at: audit) }
        let engine = ProposalEngine(workspace: "w", autonomy: Autonomy(), linear: linear, audit: AuditLog(directory: audit))
        var stored: [Proposal] = []
        for draft in result.drafts {
            guard case .store(let proposal, let applyNow) = try await engine.screen(draft, existing: stored) else {
                Issue.record("\(draft.payload.kind) was not stored")
                continue
            }
            #expect(applyNow == (proposal.kind == .addRelation))
            stored.append(await engine.apply(proposal))
        }
        #expect(stored.allSatisfy { $0.status == .applied })
        let writes = await linear.writes
        #expect(writes == [
            "close issue-3",
            "edit issue-1 to Mine.\n\n<!-- superlinear -->\nNew notes\n<!-- /superlinear -->",
            "relate issue-1 related issue-3",
            "create A gap in team-1 project=none",
            "spec spec0123 to Spec v2",
            "promote issue-2",
        ])
        // The same proposal again is pending already.
        guard case .skip = try await engine.screen(result.drafts[0], existing: [Proposal(result.drafts[0], trust: .review)]) else {
            Issue.record("A duplicate was stored")
            return
        }
    }

    @Test("Linear's answer to the planning query reads as open issues with relations")
    func linearResponse() throws {
        let response = Data(#"""
            {"issues": {"nodes": [{
              "id": "issue-2", "identifier": "SPL-2", "title": "Issue 2", "description": null, "priority": 1,
              "updatedAt": "2026-10-16T22:02:10Z", "state": {"name": "Backlog", "type": "backlog"},
              "team": {"id": "team-1", "key": "SPL"}, "project": {"id": "project-1", "name": "Planning"},
              "projectMilestone": {"name": "Beta"}, "labels": {"nodes": [{"name": "Feature"}]},
              "relations": {"nodes": [{"type": "related", "relatedIssue": {"identifier": "SPL-5"}}]},
              "inverseRelations": {"nodes": [{"type": "blocks", "issue": {"identifier": "SPL-3"}}]}
            }], "pageInfo": {"hasNextPage": false, "endCursor": null}}}
            """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let page = try decoder.decode(LinearQuery.IssuesData<LinearQuery.PlanningIssueNode>.self, from: response)
        let issue = try #require(page.issues.nodes.first?.planningIssue)
        #expect(issue.stateType == .backlog)
        #expect(issue.description == "")
        #expect(issue.projectName == "Planning")
        #expect(issue.milestone == "Beta")
        #expect(issue.relations.map(\.rendered) == ["related to SPL-5", "blocked by SPL-3"])
        #expect(issue.priority == 1)
        #expect(issue.teamKey == "SPL")

        let completed = try decoder.decode(LinearQuery.IssuesData<LinearQuery.CompletedIssueNode>.self, from: Data(#"""
            {"issues": {"nodes": [{"identifier": "SPL-3", "completedAt": "2026-10-16T22:02:10Z"}],
             "pageInfo": {"hasNextPage": false, "endCursor": null}}}
            """#.utf8))
        #expect(completed.issues.nodes.map(\.identifier) == ["SPL-3"])
    }

    // MARK: Taking in `superlinear plan`'s proposals

    @Test("The daemon takes in the proposals `plan` stored that it lacks")
    func takeIn() {
        let now = Date()
        let draft = ingest([item("closeIssue") { $0.issue = "SPL-3" }]).drafts[0]
        let fresh = Proposal(draft, trust: .review, id: "p1", now: now)
        let old = Proposal(draft, trust: .review, id: "p0", now: now.addingTimeInterval(-WorkspacePlanning.retention - 1))
        var planning = WorkspacePlanning()
        planning.proposals = [old, fresh]
        var state = State()
        let added = state.takeIn(planning, workspace: "w", now: now)
        #expect(added)
        #expect(state.proposals(workspace: "w").map(\.id) == ["p1"])
        let again = state.takeIn(planning, workspace: "w", now: now)
        #expect(!again)

        var record = PlanningRecord()
        record["w"] = planning
        // The file keeps dates to the second.
        let decoded = try? PlanningRecord.decoded(from: record.encoded())
        #expect(decoded?["w"].proposals.map(\.id) == ["p0", "p1"])
    }
}

/// A git repository in a scratch directory, on `main`, with no remote.
private struct FixtureRepository {
    let path: String

    init() throws {
        path = FileManager.default.temporaryDirectory.appendingPathComponent("superlinear-repo-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        guard Git.run(["init", "--quiet", "-b", "main"], in: path) != nil else { throw FixtureError.git("init") }
    }

    @discardableResult
    func commit(_ subject: String, body: String? = nil) throws -> GitCommit.SHA {
        var arguments = [
            "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
            "commit", "--quiet", "--allow-empty", "-m", subject,
        ]
        if let body { arguments += ["-m", body] }
        guard Git.run(arguments, in: path) != nil, let sha = Git.run(["rev-parse", "HEAD"], in: path) else {
            throw FixtureError.git("commit")
        }
        return GitCommit.SHA(rawValue: sha)
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }

    enum FixtureError: Error {
        case git(String)
    }
}
