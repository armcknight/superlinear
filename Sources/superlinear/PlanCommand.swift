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
        let planning = PlanningRecord.load()
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

        // The daemon owns the state file, so a Fable limit found here is not
        // kept: the next `plan` finds it again, and resumes on the fallback.
        var model = PlanningModel.current(limit: state.fableLimit, now: Date())
        guard var status = await launch(run, mode: .start, model: model, workspace: workspace, runner: runner, say: say) else {
            return false
        }
        if model == .fable, let hit = runner.usageLimitHit(workspace: name, now: Date()) {
            model = PlanningModel.fallback
            let until = FableLimit(hit: hit, now: Date()).until.rawValue
            say("[\(name)] Fable's usage limit is reached until \(StatusTime.clock(until, now: Date())); "
                + "resuming the job on \(model.rawValue)")
            guard let resumed = await launch(run, mode: .resume, model: model, workspace: workspace, runner: runner, say: say) else {
                return false
            }
            status = resumed
        }

        var (record, ingest) = job.finish(run, status: status, now: Date())
        for refusal in ingest.refused { say("  Refused \(refusal)") }
        let engine = ProposalEngine(
            workspace: name, autonomy: workspace.autonomy, linear: linear, audit: AuditLog(), duplicates: ClaudeDuplicateJudge())
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
                case .merge(let merged):
                    // Only a proposal of this job is this command's to change;
                    // the daemon keeps the rest.
                    if let index = stored.firstIndex(where: { $0.id == merged.id }) {
                        stored[index] = merged
                        existing = existing.map { $0.id == merged.id ? merged : $0 }
                        say("  Merged a \(draft.payload.kind.rawValue) proposal into one of this job's, the same work: \(draft.reason)")
                    } else {
                        say("  Not proposing \(draft.payload.kind.rawValue): it repeats the daemon's pending proposal \(merged.id)")
                    }
                    record.skipped += 1
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
        var latest = PlanningRecord.load()
        latest[name].running = nil
        latest[name].runs = PlanningHistory.appending(record, to: latest[name].runs)
        latest[name].proposals += stored
        latest[name].prune(now: Date())
        do {
            try latest.save()
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

    /// Launches the job's session on `model`, records it as running in the
    /// planning file, and waits for it. Returns its status, which is nil when
    /// it left none, or nil when it did not launch.
    private static func launch(
        _ run: PlanningRun, mode: LaunchMode, model: PlanningModel, workspace: WorkspaceConfig, runner: PlanningRunner,
        say: (String) -> Void
    ) async -> Int32?? {
        let name = workspace.name
        let (exits, exited) = AsyncStream<Int32?>.makeStream()
        let process: Process
        do {
            let launched: PlanningRun
            (launched, process) = try runner.launch(run, mode: mode, model: model, workspace: name, apiKey: workspace.apiKey) { status in
                exited.yield(status)
                exited.finish()
            }
            // Read the file now, in case another `plan` wrote it meanwhile.
            var planning = PlanningRecord.load()
            planning[name].running = launched
            try planning.save()
        } catch {
            say("[\(name)] Could not launch the planning job: \(error)")
            runner.cleanUp(run.sessionId)
            return nil
        }
        if mode == .start {
            say("[\(name)] Claude is planning in \(run.worktreePath) on \(model.rawValue); this takes a few minutes")
            say("  Session: \(run.sessionId)")
            say("  Log: \(runner.log(workspace: name))")
        }
        var status: Int32?
        for await exit in exits { status = exit }
        withExtendedLifetime(process) {}
        return .some(status)
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
