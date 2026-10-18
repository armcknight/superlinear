import Foundation
import Testing
@testable import superlinear

private let updated = Date(timeIntervalSince1970: 1_800_000_000)

private func issue(
    _ identifier: String, state: LinearStateType = .unstarted, description: String = "", labels: [String] = []
) -> PlanningIssue {
    let key = String(identifier.split(separator: "-")[0])
    return PlanningIssue(
        id: LinearIssue.ID(rawValue: "id-\(identifier)"), identifier: LinearIssue.Identifier(rawValue: identifier),
        title: "Title \(identifier)", description: description, stateName: state == .triage ? "Triage" : "Todo",
        stateType: state, priority: 2, teamId: LinearTeam.ID(rawValue: "team-\(key)"), teamKey: LinearTeam.Key(rawValue: key),
        projectId: nil, projectName: nil, milestone: nil, labels: labels.map { LinearLabel.Name(rawValue: $0) }, relations: [],
        updatedAt: updated, url: "https://linear.app/x/issue/\(identifier)")
}

private func workspace(
    _ name: String, key: String, issues: [PlanningIssue], proposals: [RoadmapProposal] = [],
    pullRequests: [RoadmapPullRequest] = []
) -> RoadmapWorkspace {
    RoadmapWorkspace(
        name: name, defaultBranch: "main", head: GitCommit.SHA(rawValue: String(repeating: "a", count: 40)),
        worktreePath: "/repos/\(name)",
        teams: [PlanningTeam(id: LinearTeam.ID(rawValue: "team-\(key)"), key: LinearTeam.Key(rawValue: key), name: name)],
        issues: issues, proposals: proposals, pullRequests: pullRequests, blocked: [], humanLabels: ["needs-human"],
        recentMerges: [])
}

private let templatr = workspace(
    "templatr", key: "TEM",
    issues: [
        issue("TEM-50"),
        issue("TEM-51", description: "Waits for WOR-7, and for ABC-3. UTF-8 only; see tem-50 and TEM-50."),
        issue("TEM-23", labels: ["needs-human"]),
        issue("TEM-60", state: .triage),
    ],
    proposals: [
        RoadmapProposal(kind: .createIssue, reason: "a gap", form: .triageIssue, issue: "TEM-60", url: "https://linear.app/x/issue/TEM-60"),
    ],
    pullRequests: [
        RoadmapPullRequest(
            number: 9, title: "fix: tests", url: "https://github.com/o/templatr/pull/9", issues: ["TEM-50"], isDraft: false,
            review: "not reviewed", ci: "CI passing", waitingOnYou: true),
    ])
private let workflows = workspace("workflows", key: "WOR", issues: [issue("WOR-7")])
private let context = RoadmapContext(builtAt: updated, workspaces: [templatr, workflows])

@Suite("Roadmap")
struct RoadmapTests {
    @Test("An identifier of another workspace's team in a description is a wait; one no workspace watches is unknown")
    func crossReferences() {
        #expect(context.references == [
            CrossReference(issue: "TEM-51", workspace: "templatr", target: "WOR-7", targetWorkspace: "workflows", targetOpen: true),
            CrossReference(issue: "TEM-51", workspace: "templatr", target: "ABC-3", targetWorkspace: nil, targetOpen: false),
        ])
        #expect(context.references[0].rendered(step: 1) == "TEM-51 waits for WOR-7 in workflows, step 1")
        #expect(context.references[1].rendered(step: nil) == "TEM-51 names ABC-3, of a team no workspace watches (unknown)")
    }

    @Test("Two workspaces with the same team key: an identifier alone is ambiguous, one with its workspace is not")
    func sharedKeys() {
        let workr = workspace("workr", key: "WOR", issues: [issue("WOR-7"), issue("WOR-8")])
        let other = workspace("templatr", key: "TEM", issues: [issue("TEM-1", description: "After WOR-7 and WOR-8.")])
        let context = RoadmapContext(builtAt: updated, workspaces: [other, workflows, workr])
        #expect(context.references == [
            CrossReference(
                issue: "TEM-1", workspace: "templatr", target: "WOR-7", targetWorkspace: nil, targetOpen: false,
                ambiguous: ["workflows", "workr"]),
            // Only workr has WOR-8 open, so it is workr's.
            CrossReference(issue: "TEM-1", workspace: "templatr", target: "WOR-8", targetWorkspace: "workr", targetOpen: true),
        ])
        #expect(context.references[0].rendered(step: nil) == "TEM-1 names WOR-7, of a team key in workflows and workr (ambiguous)")

        let output = RoadmapOutput(steps: [
            .init(work: "WOR-7", issues: ["WOR-7"], who: ["agent"], why: nil),
            .init(work: "workr:WOR-7 (Title WOR-7)", issues: ["workr:WOR-7"], who: ["agent"], why: nil),
        ])
        let roadmap = Roadmap.assemble(output, context: context, model: nil, usage: nil)
        #expect(roadmap.warnings == ["Step 1 names WOR-7, which is in workflows and workr; it should say which, as workflows:WOR-7"])
        #expect(roadmap.steps.map { $0.issues.map { "\($0.workspace):\($0.identifier)" } }
            == [["workr:WOR-7"], ["templatr:TEM-1"], ["workflows:WOR-7"], ["workr:WOR-8"]])
        #expect(roadmap.steps[2].work == "workflows:WOR-7 (Title WOR-7)")
        #expect(roadmap.step(of: "WOR-8", in: "workr") == 4)
        // Neither WOR-7 links, as it could be either.
        #expect(Roadmap.linked("WOR-7 WOR-8", issues: roadmap.steps.flatMap(\.issues))
            == "WOR-7 \u{1b}]8;;https://linear.app/x/issue/WOR-8\u{1b}\\WOR-8\u{1b}]8;;\u{1b}\\")

        let prompt = RoadmapPrompt.render(context, outputPath: "/o", commands: [:])
        #expect(prompt.contains("7. More than one workspace has issues with these identifiers: WOR-7."))
        #expect(prompt.contains("### workr:WOR-7: Title WOR-7"))
        #expect(prompt.contains("### WOR-8: Title WOR-8"))
    }

    @Test("A human label, a proposal in Triage and a pull request waiting for review need the owner")
    func ownerReasons() {
        let reasons = { (identifier: String) in templatr.ownerReasons(for: templatr.issues.first { $0.identifier.rawValue == identifier }!) }
        #expect(reasons("TEM-23").map(\.kind) == [.humanLabel])
        #expect(reasons("TEM-60").map(\.kind) == [.triage])
        #expect(reasons("TEM-60")[0].text == "accept or reject the proposed issue in Triage")
        #expect(reasons("TEM-50").map(\.kind) == [.review])
        #expect(reasons("TEM-50")[0].text == "review #9 (not reviewed, CI passing)")
        #expect(reasons("TEM-51").isEmpty)
    }

    @Test("Every open issue lands in one step, and the owner's issues have actions with the step they unblock")
    func assemble() {
        let output = RoadmapOutput(
            steps: [
                .init(work: "WOR-7 (Title WOR-7)", issues: ["WOR-7"], who: ["agent"], why: "TEM-51 waits for it"),
                .init(work: "Release workflows 4.2.0", issues: [], who: ["you"], why: nil),
                .init(work: "TEM-51, then `make templates-deploy`", issues: ["TEM-51", "WOR-7", "NOPE-1"], who: ["agent", "you"], why: nil),
                .init(work: "Repeats", issues: ["TEM-51"], who: ["agent"], why: nil),
                .init(work: "TEM-50 (tests)", issues: ["tem-50"], who: ["agent"], why: nil),
            ],
            actions: [.init(text: "Release workflows 4.2.0", step: 2, issues: [])],
            triage: [.init(text: "TEM-51 and TEM-60 belong together", issues: ["TEM-51", "TEM-60"])])
        let roadmap = Roadmap.assemble(output, context: context, model: .fable, usage: nil)

        #expect(roadmap.steps.map(\.number) == [1, 2, 3, 4, 5, 6])
        #expect(roadmap.steps.map { $0.issues.map(\.identifier.rawValue) } == [["WOR-7"], [], ["TEM-51"], ["TEM-50"], ["TEM-23"], ["TEM-60"]])
        #expect(roadmap.steps[2].work == "TEM-51, then `make templates-deploy`")
        // The data says the owner reviews TEM-50's pull request first.
        #expect(roadmap.steps[3].who == [.you, .agent])
        #expect(roadmap.steps[4].work == "TEM-23 (Title TEM-23)")
        #expect(roadmap.steps[4].who == [.you])
        #expect(roadmap.steps[4].why == "Not placed by the roadmap session")
        #expect(roadmap.warnings == ["Step 3 names NOPE-1, which is not an open issue of these workspaces"])

        #expect(roadmap.actions.map(\.text) == [
            "Release workflows 4.2.0",
            "TEM-50: review #9 (not reviewed, CI passing)",
            "TEM-23: labeled needs-human: do it yourself",
            "TEM-60: accept or reject the proposed issue in Triage",
        ])
        #expect(roadmap.actions.map(\.step) == [2, 4, 5, 6])
        #expect(roadmap.triage == [.init(text: "TEM-51 and TEM-60 belong together", issues: ["TEM-51", "TEM-60"])])
        #expect(roadmap.heads.keys.sorted() == ["templatr", "workflows"])
        #expect(roadmap.step(of: "WOR-7", in: "workflows") == 1)
    }

    @Test("The text has the table, the waits, Now, for you, and Triage, with links when asked")
    func rendered() {
        let output = RoadmapOutput(
            steps: [.init(work: "WOR-7 (Title WOR-7)", issues: ["WOR-7"], who: ["agent"], why: nil)],
            actions: nil, triage: [.init(text: "TEM-51 is two issues", issues: ["TEM-51"])])
        let roadmap = Roadmap.assemble(output, context: context, model: nil, usage: nil)
        let text = roadmap.rendered(now: updated, links: false)
        #expect(text.contains("Step  Work"))
        #expect(text.contains("1     WOR-7 (Title WOR-7)    agent"))
        #expect(text.contains("Waits across workspaces\n  TEM-51 waits for WOR-7 in workflows, step 1"))
        #expect(text.contains("Now, for you\n  - TEM-23: labeled needs-human: do it yourself (unblocks step 2)"))
        #expect(text.contains("\n  - TEM-50: review #9 (not reviewed, CI passing) (unblocks step 3) https://github.com/o/templatr/pull/9\n"))
        #expect(text.contains("Triage\n  - TEM-51 is two issues"))
        #expect(!text.contains("\u{1b}"))

        let linked = roadmap.rendered(now: updated, links: true)
        #expect(linked.contains("\u{1b}]8;;https://linear.app/x/issue/WOR-7\u{1b}\\WOR-7\u{1b}]8;;\u{1b}\\"))
    }

    @Test("A long Work cell wraps between words, so Who stays in view")
    func wrapsWork() {
        #expect(Roadmap.wrapped("one two three", width: 7) == ["one two", "three"])
        #expect(Roadmap.wrapped("averylongword x", width: 4) == ["averylongword", "x"])
        #expect(Roadmap.wrapped("", width: 4) == [""])

        let long = String(repeating: "word ", count: 30).trimmingCharacters(in: .whitespaces)
        let output = RoadmapOutput(steps: [.init(work: "WOR-7 " + long, issues: ["WOR-7"], who: ["you"], why: nil)])
        let text = Roadmap.assemble(output, context: context, model: nil, usage: nil).rendered(now: updated, links: false)
        let rows = text.components(separatedBy: "\n").drop { !$0.hasPrefix("Step") }.prefix(4)
        #expect(rows.allSatisfy { $0.count <= 4 + 2 + Roadmap.workWidth + 2 + "agent, then you".count })
        #expect(rows.dropFirst().first?.hasPrefix("1     WOR-7 word") == true)
        #expect(rows.dropFirst().first?.hasSuffix("  you") == true)
        #expect(rows.dropFirst(2).first?.hasPrefix("      word") == true)
    }

    @Test("status points at the roadmap: when it was built and what it asks of the owner")
    func pointer() {
        var record = RoadmapRecord()
        #expect(record.pointer(workspaces: ["a", "b"], now: updated) == "Roadmap: none built yet; `superlinear roadmap` builds one")
        let roadmap = Roadmap.assemble(RoadmapOutput(steps: []), context: context, model: nil, usage: nil)
        record.roadmaps[RoadmapRecord.key(["workflows", "templatr"])] = roadmap
        let line = record.pointer(workspaces: ["templatr", "workflows"], now: updated.addingTimeInterval(3600))
        #expect(line.hasPrefix("Roadmap: built "))
        #expect(line.hasSuffix("(1h 0m ago), 3 actions for you; see `superlinear roadmap`"))
    }

    @Test("The roadmap file keeps roadmaps by their workspaces")
    func record() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("roadmap-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var record = RoadmapRecord()
        record.roadmaps["templatr,workflows"] = Roadmap.assemble(RoadmapOutput(steps: []), context: context, model: .opus, usage: nil)
        try record.save(to: url)
        #expect(RoadmapRecord.load(from: url) == record)
        #expect(RoadmapRecord.load(from: url.appendingPathExtension("missing")) == RoadmapRecord())
    }

    @Test("The session reads each workspace through scripts that hold no key, and may run only reading commands")
    func runner() {
        let runner = RoadmapRunner(home: "/h", environment: ["LINCTL_API_KEY": "daemon-key", "PATH": "/bin"])
        let session = ClaudeSession.ID(rawValue: "s1")
        let script = RoadmapRunner.scriptText("linctl", 1, repository: "/r")
        #expect(script == "#!/bin/sh\nLINCTL_API_KEY=\"$SUPERLINEAR_LINEAR_KEY_1\" exec linctl \"$@\"\n")
        #expect(RoadmapRunner.scriptText("git", 0, repository: "/it's") == "#!/bin/sh\nexec git -C '/it'\\''s' \"$@\"\n")
        #expect(RoadmapRunner.scriptText("gh", 0, repository: "/r") == "#!/bin/sh\ncd '/r' && exec gh \"$@\"\n")

        let tools = runner.allowedTools(workspaces: 2, sessionId: session)
        #expect(tools.contains("Bash(/h/.local/share/superlinear/runs/roadmap-s1.tools/1/linctl issue get:*)"))
        #expect(tools.contains("Bash(/h/.local/share/superlinear/runs/roadmap-s1.tools/0/git log:*)"))
        #expect(!tools.contains("Bash(git"))

        let environment = runner.launchEnvironment(session, apiKeys: ["key-a", "key-b"])
        #expect(environment["LINCTL_API_KEY"] == nil)
        #expect(environment["SUPERLINEAR_LINEAR_KEY_0"] == "key-a")
        #expect(environment["SUPERLINEAR_LINEAR_KEY_1"] == "key-b")

        let arguments = runner.claudeArguments(sessionId: session, mode: .start, model: .fable, repositories: ["/a", "/b"])
        #expect(arguments.suffix(4) == ["--add-dir", "/a", "--add-dir", "/b"])
        #expect(!arguments.joined().contains("key-"))
    }

    @Test("The prompt has the waits across workspaces and what needs the owner, and no key")
    func prompt() {
        let prompt = RoadmapPrompt.render(
            context, outputPath: "/out.json", commands: ["templatr": ["linctl": "/t/0/linctl"]])
        #expect(prompt.contains("## Waits across workspaces\n\n- TEM-51 waits for WOR-7 in workflows"))
        #expect(prompt.contains("Needs the owner: labeled needs-human: do it yourself"))
        #expect(prompt.contains("- `linctl`: `/t/0/linctl`"))
        #expect(prompt.contains("#9 fix: tests — issues TEM-50 — not reviewed, CI passing — waits on the owner"))
    }

    @Test("roadmap takes workspaces, --json and --refresh")
    func arguments() {
        #expect(Command.parse(["roadmap"]) == .roadmap(configPath: nil, workspaces: nil, json: false, refresh: false))
        #expect(Command.parse(["roadmap", "--workspace", "a,b", "--workspace", "c", "--json", "--refresh", "--config", "/c.json"])
            == .roadmap(configPath: "/c.json", workspaces: ["a", "b", "c"], json: true, refresh: true))
        #expect(Command.parse(["roadmap", "--workspace"]) == .invalid("--workspace needs a name"))
        #expect(Command.parse(["roadmap", "--all"]) == .invalid("unknown option for roadmap: --all"))
    }
}
