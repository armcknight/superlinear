import Foundation

/// `superlinear plan`: runs the planning job now, in the foreground, rather
/// than waiting for the daemon to find a change that calls for one.
enum PlanCommand {
    static func run(configPath: String?, workspace: String?) async -> Int32 {
        let config: Config
        do {
            config = try Config.load(from: configPath)
        } catch {
            print("[superlinear] Failed to load config: \(error)")
            return 1
        }
        let workspaces: [WorkspaceConfig]
        if let workspace {
            guard let match = config.workspaces.first(where: { $0.name == workspace }) else {
                print("[superlinear] No workspace named \(workspace). Workspaces: \(config.workspaces.map(\.name).joined(separator: ", "))")
                return 1
            }
            workspaces = [match]
        } else {
            workspaces = config.workspaces.filter(\.planning.enabled)
            guard !workspaces.isEmpty else {
                print("[superlinear] No workspace has planning on. Set planning.enabled, or name one with --workspace.")
                return 1
            }
        }
        var succeeded = true
        for workspace in workspaces {
            succeeded = await runJob(workspace, say: { print($0) }) && succeeded
        }
        return succeeded ? 0 : 1
    }

    /// Runs one workspace's planning job and waits for it, then screens its
    /// proposals as the daemon would, applies those whose kind is `auto`, and
    /// stores them in the planning file, where the daemon takes them in and
    /// puts them in Linear. Returns whether the job ran to the end.
    static func runJob(_ workspace: WorkspaceConfig, say: (String) -> Void, runner: PlanningRunner = PlanningRunner()) async -> Bool {
        let name = workspace.name
        let state = State.loadWithPlanning(from: State.stateFileURL(), planning: PlanningRecord.load())
        var planning = PlanningRecord.load()
        if let reason = busy(state.workspaces[name] ?? WorkspaceState(), planning: planning[name]) {
            say("[\(name)] \(reason)")
            return false
        }

        let job = PlanningJob(workspace: workspace, runner: runner)
        let linear = LinearClient(apiKey: workspace.apiKey)
        let history = state.planningRuns(workspace: name, planning: planning[name])
        say("[\(name)] Gathering commits and issues")
        let run: PlanningRun
        do {
            run = try await job.prepare(history: history, trigger: .onDemand, linear: linear, now: Date())
        } catch {
            say("[\(name)] Could not start the planning job: \(error)")
            return false
        }

        let (exits, exited) = AsyncStream<Int32?>.makeStream()
        let process: Process
        do {
            let launched: PlanningRun
            (launched, process) = try runner.launch(run, mode: .start, workspace: name) { status in
                exited.yield(status)
                exited.finish()
            }
            planning[name].running = launched
            try planning.save()
        } catch {
            say("[\(name)] Could not launch the planning job: \(error)")
            runner.cleanUp(run.sessionId)
            return false
        }
        say("[\(name)] Claude is planning in \(run.worktreePath); this takes a few minutes")
        say("  Session: \(run.sessionId)")
        say("  Log: \(runner.log(workspace: name))")
        var status: Int32?
        for await exit in exits { status = exit }
        withExtendedLifetime(process) {}

        var (record, ingest) = job.finish(run, status: status, now: Date())
        for refusal in ingest.refused { say("  Refused \(refusal)") }
        let engine = ProposalEngine(workspace: name, autonomy: workspace.autonomy, linear: linear, audit: AuditLog())
        var existing = state.proposals(workspace: name)
        var stored: [Proposal] = []
        for draft in ingest.drafts {
            do {
                switch try await engine.screen(draft, existing: existing) {
                case .store(var proposal, let applyNow):
                    if applyNow { proposal = await engine.apply(proposal) }
                    existing.append(proposal)
                    stored.append(proposal)
                    record.proposed += 1
                    let applied = proposal.status == .applied ? " (applied)" : ""
                    say("  Proposed \(proposal.kind.rawValue)\(applied): \(proposal.reason)")
                case .skip(let reason):
                    record.skipped += 1
                    say("  Not proposing \(draft.payload.kind.rawValue): \(reason)")
                }
            } catch {
                record.skipped += 1
                say("  Could not check a \(draft.payload.kind.rawValue) proposal for duplicates: \(error)")
            }
        }

        // Read again, in case another `plan` wrote it meanwhile.
        planning = PlanningRecord.load()
        planning[name].running = nil
        planning[name].runs = PlanningHistory.appending(record, to: planning[name].runs)
        planning[name].proposals += stored
        planning[name].prune(now: Date())
        do {
            try planning.save()
        } catch {
            say("[\(name)] Could not save \(PlanningRecord.fileURL().path): \(error)")
            return false
        }
        runner.cleanUp(run.sessionId)

        if let error = record.error {
            say("[\(name)] The planning job failed: \(error)")
            return false
        }
        var summary = "[\(name)] The planning job proposed \(record.proposed), skipped \(record.skipped)"
        if let usage = record.usage { summary += ", and used \(Stats.compact(usage.tokens)) tokens" }
        say(summary + (record.proposed > 0 ? ". The daemon puts them in Linear at its next poll." : "."))
        return true
    }

    /// Why a job may not start now: one is running already, the daemon's or
    /// another `plan`'s.
    static func busy(_ state: WorkspaceState, planning: WorkspacePlanning) -> String? {
        if let run = state.planningRun, AgentRunner.isRunning(pid: run.pid, startedAt: run.processStartedAt) {
            return "The daemon is running the planning job now (session \(run.sessionId)); its proposals go to Linear when it ends"
        }
        if let run = planning.running, AgentRunner.isRunning(pid: run.pid, startedAt: run.processStartedAt) {
            return "`superlinear plan` is running the planning job now (session \(run.sessionId))"
        }
        return nil
    }
}
