import Foundation

/// What a planning job's session is told.
enum PlanningPrompt {
    /// The proposal kinds a planning job makes.
    static let kinds: [ProposalKind] = [.closeIssue, .editIssue, .addRelation, .createIssue, .changeSpec, .promoteIssue]

    /// The prompt that starts a job's session, which writes its proposals to
    /// `outputPath`.
    static func render(_ context: PlanningContext, outputPath: String) -> String {
        var lines: [String] = [
            """
            You are superlinear's planning job for the Linear workspace "\(context.workspace)". This job runs \
            because \(context.trigger). You run headless: do not ask questions. You are in a worktree of the \
            repository with its default branch, `\(context.defaultBranch)`, checked out at \(context.head.short). \
            Read the code with Read, Grep, Glob and `git log`, `git show` and `git diff` as you need. \
            \(LinearKey.promptLine)

            Do not change Linear, the repository or anything else. Your only output is a JSON file of proposed \
            changes, written with the Write tool to:

                \(outputPath)

            superlinear checks each proposal and stores it for its owner to approve, or applies it at once when \
            the owner trusts that kind. Propose only changes you are confident of, each with a short reason that \
            names the evidence: a commit, a file, a line of the spec. Propose nothing rather than guess. When there \
            is nothing to propose, write `{"proposals": []}`.

            Look for:

            1. Issues that the merged changes made obsolete or already did: `closeIssue`, with the commit.
            2. Issue descriptions whose assumptions the changes broke: `editIssue`. For an issue with the label \
            "superlinear", `newText` replaces the whole description; for any other issue it replaces only the \
            managed block between `<!-- superlinear -->` and `<!-- /superlinear -->`, shown below as its current \
            managed block, so write the whole of the new block.
            3. Missing relations between issues, and duplicates: `addRelation`, with `relationType` one of \
            `blocks`, `duplicate`, `related` or `similar`. The issue in `issue` is the relation's subject: it \
            blocks, or is the duplicate of, `relatedIssue`.
            4. Gaps: work that the spec or a project's exit criteria need but that no issue covers (`createIssue`), \
            and issues the owner created that have no acceptance criteria or spec references (`editIssue`, adding \
            them in the managed block).
            5. Places where the code and the spec no longer agree: `changeSpec` to bring the spec in line with the \
            code, or `createIssue` to fix the code, whichever is right.
            6. Issues in the backlog that are now unblocked and ready to build: `promoteIssue`, which moves one to Todo.

            Leave alone issues with the label "superlinear: hands off". Do not propose a relation that exists.

            The file holds one object with a `proposals` array. Each proposal has `kind`, `reason`, and the fields \
            its kind needs; `commit` (a SHA) or `pullRequest` (its number) says which change it comes from, when \
            one does:

                {"kind": "closeIssue", "issue": "ABC-12", "reason": "…", "commit": "1a2b3c4"}
                {"kind": "editIssue", "issue": "ABC-12", "newText": "…", "reason": "…"}
                {"kind": "addRelation", "issue": "ABC-12", "relatedIssue": "ABC-14", "relationType": "blocks", "reason": "…"}
                {"kind": "createIssue", "team": "ABC", "project": "<project ID>", "title": "…", "description": "…", \
            "relatedIssue": "ABC-12", "reason": "…"}
                {"kind": "changeSpec", "spec": "document", "newText": "…", "reason": "…"}
                {"kind": "changeSpec", "spec": "<project ID>", "newText": "…", "reason": "…"}
                {"kind": "promoteIssue", "issue": "ABC-12", "reason": "…"}

            In `createIssue`, `project` and `relatedIssue` are optional. In `changeSpec`, `spec` is `document` for \
            the spec document, or a project's ID for its description; `newText` is the whole new text.
            """,
        ]

        lines.append("\n## Commits on \(context.defaultBranch) since the last run (\(context.range))\n")
        if context.commits.isEmpty { lines.append("None.") }
        for commit in context.commits {
            var line = "- \(commit.sha.short) \(commit.subject) (\(commit.author), \(ISO8601DateFormatter().string(from: commit.date)))"
            if let pullRequest = commit.pullRequest { line += " — pull request #\(pullRequest.number) \(pullRequest.url)" }
            if !commit.issues.isEmpty { line += " — issues \(commit.issues.map(\.rawValue).joined(separator: ", "))" }
            lines.append(line)
            if !commit.body.isEmpty { lines.append(indented(commit.body, by: "    ")) }
        }

        lines.append("\n## Issues completed since the last job\n")
        lines.append(
            context.completedIssues.isEmpty
                ? "None."
                : "\(context.completedIssues.map(\.rawValue).joined(separator: ", ")). They are no longer among the open issues below; "
                    + "issues they blocked may now be ready.")

        lines.append("\n## Teams\n")
        for team in context.teams { lines.append("- \(team.key): \(team.name)") }

        lines.append("\n## Projects\n")
        if context.projects.isEmpty { lines.append("None.") }
        for project in context.projects {
            lines.append("### \(project.name) (ID \(project.id))\n")
            if !project.milestones.isEmpty {
                lines.append("Milestones: " + project.milestones.map(\.name.rawValue).joined(separator: ", "))
            }
            lines.append(project.content.isEmpty ? "(No description.)" : project.content)
            lines.append("")
        }

        lines.append("\n## Open issues\n")
        if context.issues.isEmpty { lines.append("None.") }
        for issue in context.issues.sorted(by: { $0.identifier.sortsBefore($1.identifier) }) {
            lines.append("### \(issue.identifier): \(issue.title)\n")
            var facts = ["State: \(issue.stateName) (\(issue.stateType.rawValue))"]
            if let priority = issue.priority, priority.rawValue > 0 { facts.append("Priority: \(Int(priority.rawValue))") }
            if let project = issue.projectName { facts.append("Project: \(project)") }
            if let milestone = issue.milestone { facts.append("Milestone: \(milestone)") }
            if !issue.labels.isEmpty { facts.append("Labels: \(issue.labels.map(\.rawValue).joined(separator: ", "))") }
            if !issue.relations.isEmpty { facts.append("Relations: \(issue.relations.map(\.rendered).joined(separator: ", "))") }
            lines.append(facts.joined(separator: " · "))
            lines.append("")
            lines.append(issue.description.isEmpty ? "(No description.)" : issue.description)
            if !issue.createdBySuperlinear {
                lines.append("\nCurrent managed block: " + (ManagedBlock.contents(of: issue.description).map { "\n" + $0 } ?? "none"))
            }
            lines.append("")
        }

        if let spec = context.spec {
            lines.append("\n## Spec document (\(spec.url))\n")
            lines.append(spec.content.isEmpty ? "(Empty.)" : spec.content)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The prompt that resumes an interrupted session.
    static func resume(outputPath: String) -> String {
        """
        You were interrupted partway through the planning job above. Carry on where you stopped, and write the \
        proposals file to \(outputPath) as described. If you wrote it already, stop.
        """
    }

    private static func indented(_ text: String, by prefix: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { prefix + $0 }.joined(separator: "\n")
    }
}

/// The file a planning job's session writes.
struct PlanningOutput: Decodable, Sendable, Equatable {
    var proposals: [Item]

    /// One proposal as the session wrote it. Every field but `kind` may be
    /// absent; checking it says which a kind needs.
    struct Item: Decodable, Sendable, Equatable {
        var kind: String
        var reason: String?
        var issue: String?
        var relatedIssue: String?
        var relationType: String?
        var newText: String?
        var title: String?
        var description: String?
        var team: String?
        var project: String?
        var spec: String?
        var commit: String?
        var pullRequest: PullRequestReference?

        init(kind: String) { self.kind = kind }
    }

    /// A pull request by number, as `7`, or `"#7"`, or by URL.
    struct PullRequestReference: Decodable, Sendable, Equatable {
        var text: String

        init(_ text: String) { self.text = text }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int.self) {
                text = String(number)
            } else {
                text = try container.decode(String.self)
            }
        }
    }

    static func decoded(from data: Data) throws -> PlanningOutput {
        try JSONDecoder().decode(PlanningOutput.self, from: data)
    }
}

/// The proposals a job's output makes, checked against what it was given,
/// and those refused, each with why.
struct PlanningIngest: Sendable, Equatable {
    var drafts: [ProposalDraft] = []
    var refused: [String] = []

    init() {}

    init(_ output: PlanningOutput, context: PlanningContext, sessionId: ClaudeSession.ID) {
        for (index, item) in output.proposals.enumerated() {
            switch Self.draft(item, context: context, sessionId: sessionId) {
            case .success(let draft): drafts.append(draft)
            case .failure(let refusal): refused.append("Proposal \(index + 1) (\(item.kind)): \(refusal.reason)")
            }
        }
    }

    struct Refusal: Error, Equatable {
        var reason: String
    }

    private static func draft(
        _ item: PlanningOutput.Item, context: PlanningContext, sessionId: ClaudeSession.ID
    ) -> Result<ProposalDraft, Refusal> {
        func refuse(_ reason: String) -> Result<ProposalDraft, Refusal> { .failure(Refusal(reason: reason)) }
        guard let kind = ProposalKind(rawValue: item.kind), PlanningPrompt.kinds.contains(kind) else {
            return refuse("not a kind the planning job proposes")
        }
        guard let reason = nonEmpty(item.reason) else { return refuse("it has no reason") }
        let source = source(of: item, context: context, sessionId: sessionId)
        func make(_ payload: ProposalPayload, _ target: ProposalTarget, _ updatedAt: Date?) -> Result<ProposalDraft, Refusal> {
            .success(ProposalDraft(payload: payload, target: target, reason: reason, source: source, targetUpdatedAt: updatedAt))
        }
        func openIssue(_ identifier: String?, field: String) -> Result<PlanningIssue, Refusal> {
            guard let identifier = nonEmpty(identifier) else { return .failure(Refusal(reason: "it has no \(field)")) }
            guard let issue = context.issue(identifier) else {
                return .failure(Refusal(reason: "\(identifier) is not an open issue of the workspace"))
            }
            return .success(issue)
        }

        switch kind {
        case .closeIssue, .editIssue, .promoteIssue, .addRelation:
            let issue: PlanningIssue
            switch openIssue(item.issue, field: "issue") {
            case .success(let found): issue = found
            case .failure(let refusal): return .failure(refusal)
            }
            if issue.handsOff { return refuse("\(issue.identifier) has the label \"\(ProposalEngine.handsOffLabel)\"") }
            let target = ProposalTarget.issue(issue.id, name: issue.identifier.rawValue)
            switch kind {
            case .closeIssue:
                return make(.closeIssue, target, issue.updatedAt)
            case .promoteIssue:
                guard issue.stateType == .backlog else { return refuse("\(issue.identifier) is not in the backlog") }
                return make(.promoteIssue, target, issue.updatedAt)
            case .editIssue:
                guard let newText = item.newText?.trimmingCharacters(in: .whitespacesAndNewlines), !newText.isEmpty else {
                    return refuse("it has no newText")
                }
                let oldText = issue.editableText
                guard newText != oldText.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return refuse("newText is the text \(issue.identifier) has")
                }
                return make(.editIssue(oldText: oldText, newText: newText), target, issue.updatedAt)
            default:
                let related: PlanningIssue
                switch openIssue(item.relatedIssue, field: "relatedIssue") {
                case .success(let found): related = found
                case .failure(let refusal): return .failure(refusal)
                }
                guard related.id != issue.id else { return refuse("an issue cannot relate to itself") }
                guard let type = item.relationType.flatMap({ LinearRelationType(rawValue: $0.lowercased()) }) else {
                    return refuse("relationType must be one of \(LinearRelationType.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                let exists = issue.relations.contains {
                    $0.identifier == related.identifier && $0.type == type && ($0.direction == .outgoing || !type.isDirected)
                } || related.relations.contains {
                    $0.identifier == issue.identifier && $0.type == type && ($0.direction == .incoming || !type.isDirected)
                }
                if exists { return refuse("the relation \(issue.identifier) \(type.rawValue) \(related.identifier) exists already") }
                return make(.addRelation(relatedIssueId: related.id, type: type.rawValue), target, nil)
            }

        case .createIssue:
            guard let title = nonEmpty(item.title) else { return refuse("it has no title") }
            guard let teamText = nonEmpty(item.team),
                  let team = context.teams.first(where: {
                      $0.key.rawValue.caseInsensitiveCompare(teamText) == .orderedSame || $0.id.rawValue == teamText
                  })
            else { return refuse("its team is not one of \(context.teams.map(\.key.rawValue).joined(separator: ", "))") }
            var projectId: LinearProject.ID?
            if let projectText = nonEmpty(item.project) {
                guard let project = project(projectText, in: context) else { return refuse("\(projectText) is not a known project") }
                projectId = project.id
            }
            var relatedId: LinearIssue.ID?
            if let relatedText = nonEmpty(item.relatedIssue) {
                guard let related = context.issue(relatedText) else { return refuse("\(relatedText) is not an open issue of the workspace") }
                relatedId = related.id
            }
            return make(
                .createIssue(
                    teamId: team.id, projectId: projectId, title: title,
                    description: item.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    relatedIssueId: relatedId),
                .team(team.id, name: team.key.rawValue), nil)

        case .changeSpec:
            guard let newText = item.newText?.trimmingCharacters(in: .whitespacesAndNewlines), !newText.isEmpty else {
                return refuse("it has no newText")
            }
            let specText = nonEmpty(item.spec) ?? "document"
            if specText.lowercased() == "document" {
                guard let spec = context.spec else { return refuse("the workspace has no spec document") }
                guard newText != spec.content.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return refuse("newText is the spec document's text")
                }
                return make(.changeSpec(oldText: spec.content, newText: newText), .document(spec.id, name: "the spec"), spec.updatedAt)
            }
            guard let project = project(specText, in: context) else { return refuse("\(specText) is not a known project") }
            guard newText != project.content.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return refuse("newText is \(project.name)'s description")
            }
            return make(
                .changeSpec(oldText: project.content, newText: newText), .project(project.id, name: project.name.rawValue),
                project.updatedAt)

        case .postProjectUpdate:
            return refuse("not a kind the planning job proposes")
        }
    }

    /// Where the proposal comes from: the pull request or commit it names,
    /// when the job was given it, or else the job's whole commit range, or
    /// its session when there were no commits.
    static func source(of item: PlanningOutput.Item, context: PlanningContext, sessionId: ClaudeSession.ID) -> ProposalSource {
        if let reference = item.pullRequest?.text.trimmingCharacters(in: .whitespaces) {
            let number = Int(reference.trimmingCharacters(in: CharacterSet(charactersIn: "#")))
            if let pullRequest = context.commits.compactMap(\.pullRequest).first(where: {
                $0.url == reference || $0.number.rawValue == number
            }) {
                return ProposalSource(kind: .pullRequest, value: pullRequest.url)
            }
        }
        if let sha = nonEmpty(item.commit)?.lowercased(), sha.count >= 7,
           let commit = context.commits.first(where: { $0.sha.rawValue.lowercased().hasPrefix(sha) }) {
            if let pullRequest = commit.pullRequest { return ProposalSource(kind: .pullRequest, value: pullRequest.url) }
            return ProposalSource(kind: .commitRange, value: commit.sha.short)
        }
        if !context.commits.isEmpty { return ProposalSource(kind: .commitRange, value: context.range) }
        return ProposalSource(kind: .agentSession, value: sessionId.rawValue)
    }

    private static func project(_ text: String, in context: PlanningContext) -> PlanningProject? {
        context.projects.first { $0.id.rawValue == text || $0.name.rawValue.caseInsensitiveCompare(text) == .orderedSame }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
