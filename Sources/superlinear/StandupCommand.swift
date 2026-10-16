import Foundation

/// How the standup talks to the owner. The terminal does it for real; tests
/// script it.
protocol StandupIO {
    func say(_ text: String)
    /// The owner's answer, or nil at the end of input.
    func ask(_ prompt: String) -> String?
    /// `text` as the owner left it in their editor, or nil when the editor failed.
    func edit(_ text: String) -> String?
}

struct TerminalIO: StandupIO {
    func say(_ text: String) {
        print(text)
    }

    func ask(_ prompt: String) -> String? {
        print(prompt, terminator: "")
        fflush(stdout)
        return readLine()
    }

    /// Opens `$EDITOR`, or `vi`, on a scratch file holding `text`.
    func edit(_ text: String) -> String? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("superlinear-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            // The editor may carry arguments, as `code --wait` does.
            process.arguments = ["-c", "${EDITOR:-vi} \"$1\"", "sh", url.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            print("Could not open the editor: \(error)")
            return nil
        }
    }
}

/// The owner quit the standup; nothing is applied or recorded.
struct StandupAborted: Error {}

/// Walks the owner through one workspace's standup, section by section, and
/// returns what they decided.
struct StandupPrompter {
    let io: any StandupIO

    /// What the owner can do with a proposal. Enter defers it.
    enum ProposalAction: String {
        case approve = "a"
        case edit = "e"
        case reject = "r"
        case `defer` = "d"

        init?(answer: String?) {
            guard let answer, !answer.isEmpty else { self = .defer; return }
            self.init(rawValue: answer.lowercased())
        }
    }

    /// What the owner can do with an issue that needs a human. Enter skips it.
    enum NeedsHumanAction: String {
        case markDone = "d"
        case enterDecision = "e"
        case skip = "s"

        init?(answer: String?) {
            guard let answer, !answer.isEmpty else { self = .skip; return }
            self.init(rawValue: answer.lowercased())
        }
    }

    /// The commands that change the plan, each taking an item's number.
    enum PlanCommand: String {
        case toggleHold = "h"
        case moveUp = "u"
        case moveDown = "d"
        case togglePromotion = "p"
    }

    func run(_ view: StandupView, standup: WorkspaceStandup) throws -> StandupSession {
        var session = StandupSession(view: view, standup: standup)
        io.say(view.rendered(sections: []))
        for section in [StandupSection.done, .waitingOnYou] {
            io.say("\n" + view.rendered(section: section).joined(separator: "\n"))
        }
        try proposals(&session)
        try needsHuman(&session)
        try plan(&session)
        io.say("\n" + view.rendered(section: .risks).joined(separator: "\n"))
        return session
    }

    private func answer(_ prompt: String) throws -> String? {
        guard let answer = io.ask(prompt)?.trimmingCharacters(in: .whitespaces) else { return nil }
        if answer.lowercased() == "q" { throw StandupAborted() }
        return answer
    }

    private func proposals(_ session: inout StandupSession) throws {
        io.say("\n" + StandupSection.proposals.title)
        guard !session.view.proposals.isEmpty else { io.say("   None pending"); return }
        for original in session.view.proposals {
            var proposal = original
            io.say(ProposalsCommand.describe(proposal, now: session.view.now).joined(separator: "\n"))
            asking: while true {
                switch ProposalAction(answer: try answer("   [a]pprove, [e]dit, [r]eject, [d]efer (default), [q]uit? ")) {
                case .approve:
                    session.approve(proposal)
                    break asking
                case .edit:
                    guard let text = io.edit(try StandupSession.editable(proposal.payload)) else {
                        io.say("   Not edited")
                        continue
                    }
                    do {
                        proposal = try StandupSession.edited(proposal, text: text)
                        io.say(ProposalsCommand.change(proposal.payload).map { "      " + $0 }.joined(separator: "\n"))
                    } catch {
                        io.say("   \(error)")
                    }
                case .reject:
                    session.reject(original, reason: try answer("   Reason: "), now: session.view.now)
                    break asking
                case .defer:
                    session.defer(original)
                    break asking
                case nil:
                    io.say("   Type a, e, r, d or q")
                }
            }
        }
    }

    private func needsHuman(_ session: inout StandupSession) throws {
        io.say("\n" + StandupSection.needsHuman.title)
        guard !session.view.needsHuman.isEmpty else { io.say("   Nothing"); return }
        for item in session.view.needsHuman {
            io.say(StandupView.describe(item))
            asking: while true {
                switch NeedsHumanAction(answer: try answer("   mark [d]one, [e]nter a decision, [s]kip (default), [q]uit? ")) {
                case .markDone:
                    session.markDone(item)
                    break asking
                case .enterDecision:
                    session.addDecision(item, text: try answer("   Decision: ") ?? "")
                case .skip:
                    break asking
                case nil:
                    io.say("   Type d, e, s or q")
                }
            }
        }
    }

    private func plan(_ session: inout StandupSession) throws {
        io.say("\n" + StandupSection.plan.title)
        if !session.view.unblocked.isEmpty {
            io.say("   Unblocked at the last standup: \(StandupView.list(session.view.unblocked))")
        }
        io.say(session.renderedPlan().joined(separator: "\n"))
        guard !session.plan.isEmpty || !session.view.backlog.isEmpty else { return }
        while let line = try answer("   h N hold or release, u N up, d N down, p bN promote, Enter when done, q quit: "),
              !line.isEmpty {
            let parts = line.lowercased().split(separator: " ", maxSplits: 1).map(String.init)
            let argument = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            let number = Int(argument.hasPrefix("b") ? String(argument.dropFirst()) : argument)
            guard let letter = parts.first, let number, number > 0 else {
                io.say("   Type a letter and a number, as in u 2 or p b1")
                continue
            }
            guard let command = PlanCommand(rawValue: letter) else {
                io.say("   Type h, u, d or p and a number")
                continue
            }
            do {
                switch command {
                case .toggleHold: try session.toggleHold(number - 1)
                case .moveUp: try session.moveUp(number - 1)
                case .moveDown: try session.moveDown(number - 1)
                case .togglePromotion: try session.togglePromotion(number - 1)
                }
            } catch {
                io.say("   \(error)")
                continue
            }
            io.say(session.renderedPlan().joined(separator: "\n"))
        }
    }
}

/// What applying a standup came to.
struct StandupOutcome: Sendable, Equatable {
    /// The workspace's standup record, updated with the standup.
    var standup: WorkspaceStandup
    /// What was done, a line each, for the owner.
    var summary: [String]
}

/// Applies what the owner decided at a standup, and records it.
struct StandupApplier {
    let engine: ProposalEngine
    let linear: any StandupWriting
    /// The spec document decisions are added to, if any.
    var specDocument: LinearDocument.ID?

    /// Applies `session` and returns the workspace's standup record updated
    /// with it, and a summary.
    func apply(
        _ session: StandupSession, state: WorkspaceState, standup: WorkspaceStandup, now: Date = Date()
    ) async -> StandupOutcome {
        var summary: [String] = []
        var outcomes: [Proposal] = []
        var closed: Set<LinearIssue.Identifier> = []

        for proposal in session.approved {
            let result = await engine.apply(proposal, now: now)
            outcomes.append(result)
            let name = "\(result.kind.rawValue) → \(Standup.targetName(result.target))"
            switch result.status {
            case .applied:
                summary.append("Applied \(name)")
                if result.kind == .closeIssue, let identifier = result.target.name {
                    closed.insert(LinearIssue.Identifier(rawValue: identifier))
                }
            case .rejected:
                summary.append("Rejected \(name): \(result.rejectionReason ?? "no reason")")
            default:
                summary.append("Could not apply \(name): \(result.lastError ?? result.reviewNote ?? "unknown")")
            }
        }
        for proposal in session.rejected {
            outcomes.append(proposal)
            summary.append("Rejected \(proposal.kind.rawValue) → \(Standup.targetName(proposal.target))"
                + (proposal.rejectionReason.map { ": \($0)" } ?? ""))
        }
        if !session.deferred.isEmpty {
            summary.append("Deferred \(session.deferred.count) proposal\(session.deferred.count == 1 ? "" : "s")")
        }

        for item in session.done {
            do {
                let moved = try await linear.completeIssue(id: item.id)
                summary.append(moved ? "Marked \(item.issue.identifier) done" : "\(item.issue.identifier) was closed already")
                closed.insert(item.issue.identifier)
            } catch {
                summary.append("Could not mark \(item.issue.identifier) done: \(error)")
            }
        }

        let day = StandupSession.dayFormatter.string(from: now)
        var recorded: [StandupDecision] = []
        for decision in session.decisions {
            let (item, text) = (decision.item, decision.text)
            let identifier = item.issue.identifier
            do {
                let issue = try await linear.editableIssue(id: item.id)
                let line = "Decision, \(day): \(text)"
                let block = ManagedBlock.contents(of: issue.description).map { $0.isEmpty ? line : $0 + "\n\n" + line } ?? line
                _ = try await linear.updateIssueDescription(
                    id: item.id, description: ManagedBlock.replacing(in: issue.description, with: block))
                recorded.append(StandupDecision(time: now, identifier: identifier, text: text))
                summary.append("Added the decision to \(identifier)")
            } catch {
                summary.append("Could not add the decision to \(identifier): \(error)")
                continue
            }
            guard let specDocument else { continue }
            do {
                let target = ProposalTarget.document(specDocument)
                let spec = try await linear.spec(of: target)
                let separator = spec.content.isEmpty ? "" : spec.content.hasSuffix("\n") ? "\n" : "\n\n"
                _ = try await linear.updateSpec(of: target, content: spec.content + separator + "- \(day) \(identifier): \(text)")
                summary.append("Added the decision on \(identifier) to the spec document")
            } catch {
                summary.append("Could not add the decision on \(identifier) to the spec document: \(error)")
            }
        }

        for item in session.promoted {
            do {
                _ = try await linear.promoteIssue(id: item.issueId)
                summary.append("Promoted \(item.identifier) to Todo")
            } catch {
                summary.append("Could not promote \(item.identifier): \(error)")
            }
        }

        var record = standup
        record.lastStandupAt = now
        for proposal in session.view.proposals where record.proposalsShownAt[proposal.id] == nil {
            record.proposalsShownAt[proposal.id] = now
        }
        record.proposalOutcomes += outcomes
        record.decisions += recorded
        let newlyHeld = session.held.filter { standup.held[$0.key] == nil }.map(\.value).sorted()
        let released = standup.held.filter { session.held[$0.key] == nil }.map(\.value).sorted()
        if !newlyHeld.isEmpty { summary.append("Holding \(StandupView.list(newlyHeld))") }
        if !released.isEmpty { summary.append("Released \(StandupView.list(released))") }
        record.held = session.held
        if session.reordered {
            record.order = session.plan.map(\.issueId)
            summary.append("Agents start in the order " + StandupView.list(session.plan.map(\.identifier)))
        }
        record.unblocked = Standup.unblocked(state.blocked, closing: closed)
        if !record.unblocked.isEmpty { summary.append("Unblocked \(StandupView.list(record.unblocked))") }
        record.prune(now: now)
        return StandupOutcome(standup: record, summary: summary)
    }
}

/// `superlinear standup`.
enum StandupCommand {
    /// How many backlog issues the plan offers to promote.
    static let backlogShown = 10

    static func run(configPath: String?, workspace: String?, printOnly: Bool, io: any StandupIO = TerminalIO()) async -> Int32 {
        let config: Config
        do {
            config = try Config.load(from: configPath)
        } catch {
            print("[superlinear] Failed to load config: \(error)")
            return 1
        }
        // Without a person to answer, every proposal would be deferred and
        // the standup still recorded as done.
        if !printOnly, io is TerminalIO, isatty(STDIN_FILENO) == 0 {
            print("[superlinear] The standup asks questions, so it needs a terminal. Use --print to read it without one.")
            return 1
        }
        var workspaces = config.workspaces
        if let workspace {
            guard let match = workspaces.first(where: { $0.name == workspace }) else {
                print("[superlinear] No workspace named \(workspace). Workspaces: \(workspaces.map(\.name).joined(separator: ", "))")
                return 1
            }
            workspaces = [match]
        }
        var record = StandupRecord.load()
        let state = State.loadWithStandups(standups: record)

        // TODO: SPL-11 adds `superlinear plan`. When its last run is older
        // than 12 hours, offer to run it first, with its token cost.

        for (index, workspace) in workspaces.enumerated() {
            let workspaceState = state.workspaces[workspace.name] ?? WorkspaceState()
            let view = await gather(
                workspace, state: workspaceState, standup: record[workspace.name], full: !printOnly,
                pauses: Standup.Pauses(state: state, workspace: workspace.name))
            if printOnly {
                io.say((index > 0 ? "\n" : "") + view.rendered(sections: StandupView.printedSections))
                continue
            }
            let session: StandupSession
            do {
                session = try StandupPrompter(io: io).run(view, standup: record[workspace.name])
            } catch {
                io.say("\nQuit the standup; nothing was applied or recorded for \(workspace.name).")
                return 0
            }
            let applier = StandupApplier(
                engine: ProposalEngine(
                    workspace: workspace.name, autonomy: workspace.autonomy,
                    linear: LinearClient(apiKey: workspace.apiKey), audit: AuditLog()),
                linear: LinearClient(apiKey: workspace.apiKey),
                specDocument: workspace.planning.specDocumentId
            )
            let outcome = await applier.apply(session, state: workspaceState, standup: record[workspace.name])
            let summary = outcome.summary
            record[workspace.name] = outcome.standup
            do {
                try record.save()
            } catch {
                io.say("Could not save \(StandupRecord.fileURL().path): \(error)")
                return 1
            }
            io.say("\nSummary for \(workspace.name)")
            io.say((summary.isEmpty ? ["Nothing changed"] : summary).map { "  " + $0 }.joined(separator: "\n"))
        }
        if !printOnly { offerResume(state: state, io: io) }
        return 0
    }

    /// Offers to end the Claude pause, as `superlinear resume` does, when one
    /// is active: once, as it is for all workspaces.
    static func offerResume(
        state: State, io: any StandupIO, resume: (State) -> String = { ResumeCommand.resume(state: $0, daemon: DaemonStatus.read()).0 },
        now: Date = Date()
    ) {
        guard let pause = state.claudePause, !pause.isOver(now: now) else { return }
        let answer = io.ask(
            "\nClaude sessions are paused at the usage limit until \(StatusTime.clock(pause.until, now: now)). "
                + "Resume them now, as after buying more usage? [y/N] ")
        guard answer?.trimmingCharacters(in: .whitespaces).lowercased() == "y" else { return }
        io.say(resume(state))
    }

    /// The view of one workspace. `full` adds what only the interactive
    /// standup shows: pull requests waiting on the owner, the backlog, and risks.
    static func gather(
        _ workspace: WorkspaceConfig, state: WorkspaceState, standup: WorkspaceStandup, full: Bool,
        pauses: Standup.Pauses = Standup.Pauses(), now: Date = Date()
    ) async -> StandupView {
        let client = LinearClient(apiKey: workspace.apiKey)
        var warnings: [String] = []
        let handled = Set(state.processedIssueIds.union(state.inFlight.keys).union(state.pendingMerges.keys)
            .map(LinearIssue.ID.init(rawValue:)))

        // In `new` mode the daemon queues new issues as it finds them, so the
        // queue is all there is.
        var upcoming: [LinearIssue] = []
        if workspace.selection == .ready {
            do {
                let ready = try await client.fetchReadyIssues(states: workspace.readyStates, teamIds: workspace.teamIds)
                upcoming = IssueSelection.plan(ready, workspace: workspace, handled: handled).start
            } catch {
                warnings.append("Could not fetch the ready issues from Linear: \(error)")
            }
        }
        var view = StandupView(workspace: workspace.name, state: state, standup: standup, upcoming: upcoming, now: now)
        view.warnings = warnings
        guard full else { return view }

        do {
            let backlog = try await client.fetchReadyIssues(states: [.backlog], teamIds: workspace.teamIds)
                .filter { !handled.contains($0.id) }
                .sorted(by: IssueSelection.readyOrder)
            view.backlog = backlog.prefix(backlogShown).map {
                PlanItem(issueId: $0.id, identifier: $0.identifier, title: $0.title)
            }
        } catch {
            view.warnings.append("Could not fetch the backlog from Linear: \(error)")
        }

        let repoPath = NSString(string: workspace.repoPath).expandingTildeInPath
        do {
            view.waitingOnYou = Standup.waitingOnYou(try ReviewablePullRequest.listOpen(in: repoPath), state: state)
        } catch {
            view.warnings.append("Could not list open pull requests: \(error)")
        }
        view.risks = risks(repoPath: repoPath, pauses: pauses, now: now, warnings: &view.warnings)
        return view
    }

    private static func risks(repoPath: String, pauses: Standup.Pauses, now: Date, warnings: inout [String]) -> [String] {
        let branch = Git.run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: repoPath)
            .map { String($0.dropFirst("origin/".count)) }
        var latest: Standup.DefaultBranchRun?
        if let branch {
            do {
                let data = try GitHubCLI.run(
                    ["run", "list", "--branch", branch, "--limit", "1", "--json", "status,conclusion,url,workflowName"],
                    in: repoPath)
                latest = try JSONDecoder().decode([Standup.DefaultBranchRun].self, from: data).first
            } catch {
                warnings.append("Could not check CI on \(branch): \(error)")
            }
        }
        var rateLimit: Standup.RateLimit?
        do {
            rateLimit = try decodeRateLimit(try GitHubCLI.run(["api", "rate_limit"], in: repoPath))
        } catch {
            warnings.append("Could not check GitHub's rate limit: \(error)")
        }
        return Standup.risks(defaultBranch: branch, latestRun: latest, rateLimit: rateLimit, pauses: pauses, now: now)
    }

    /// The GraphQL limit, which `gh pr list` spends, from `gh api rate_limit`.
    static func decodeRateLimit(_ data: Data) throws -> Standup.RateLimit? {
        struct Response: Decodable {
            struct Resources: Decodable { let graphql: Limit? }
            struct Limit: Decodable { let limit: Int; let remaining: Int; let reset: TimeInterval }
            let resources: Resources
        }
        guard let limit = try JSONDecoder().decode(Response.self, from: data).resources.graphql else { return nil }
        return Standup.RateLimit(remaining: limit.remaining, limit: limit.limit, reset: Date(timeIntervalSince1970: limit.reset))
    }
}
