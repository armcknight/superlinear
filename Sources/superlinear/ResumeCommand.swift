import Darwin
import Foundation

/// `superlinear resume`: ends the pause of Claude sessions at once, as when
/// the owner bought more usage or changed plans before the reset time. A
/// running daemon is asked through SIGUSR1, as it owns the state file;
/// otherwise the pause is lifted in the file, for the daemon to find when it
/// starts.
enum ResumeCommand {
    static func run() -> Int32 {
        let (message, status) = resume(state: State.load(), daemon: DaemonStatus.read())
        print(message)
        return status
    }

    /// What to do, given the state file and the daemon: the message to print
    /// and the exit status.
    static func resume(
        state: State, daemon: DaemonStatus, signal: (Int32) -> Bool = { kill($0, SIGUSR1) == 0 },
        save: (State) throws -> Void = { try $0.save() }, now: Date = Date()
    ) -> (String, Int32) {
        guard let pause = state.claudePause, !pause.isOver(now: now) else {
            return ("[superlinear] Claude sessions are not paused", 0)
        }
        let waiting = state.queuedRuns.count
        if daemon.running, let pid = daemon.info?.pid ?? daemon.lockPid {
            guard signal(pid) else { return ("[superlinear] Could not signal the daemon (pid \(pid))", 1) }
            return ("[superlinear] Asked the daemon to resume \(waiting) waiting session(s) now", 0)
        }
        var state = state
        state.liftClaudePause()
        do {
            try save(state)
        } catch {
            return ("[superlinear] Could not save the state file: \(error)", 1)
        }
        return ("[superlinear] Lifted the Claude pause; the daemon is not running, and resumes "
            + "\(waiting) waiting session(s) when it starts", 0)
    }
}
