import Foundation

/// Applies changes to the config file without a manual reload.
///
/// The daemon reads its config once, at start, so it checks the file every
/// few seconds instead. When the contents change to a config that loads, a
/// daemon launchd started exits and launchd starts it again on the new config,
/// as it does after a Homebrew upgrade. Agents in flight outlive the exit, and
/// the queue is in the state file, so nothing is lost.
///
/// A change that does not load — a half-saved edit, a JSON error, no
/// workspaces, a missing file — is logged once and otherwise ignored, so the
/// daemon keeps running on the config it has. A daemon launchd did not start
/// only logs that a restart is needed, since nothing would start it again.
struct ConfigWatcher {
    static let interval: TimeInterval = 5

    enum Action: Equatable {
        case none
        case restart
        /// The file changed, but to something that would not start a daemon.
        case invalid(String)
    }

    /// What to do, given the config the daemon started with and the file's
    /// contents now (nil when it cannot be read).
    static func action(started: Data, current: Data?) -> Action {
        guard let current else { return .invalid("the config file cannot be read") }
        guard current != started else { return .none }
        do {
            let config = try Config.decoded(from: current)
            return config.workspaces.isEmpty ? .invalid("no workspaces are configured") : .restart
        } catch {
            return .invalid("\(error)")
        }
    }

    private let timer: DispatchSourceTimer

    /// Starts watching `path`, whose contents the daemon started with, on the
    /// main queue. `restartable` is whether exiting gets the daemon started
    /// again, as it does under launchd.
    static func start(path: String, started: Data, restartable: Bool) -> ConfigWatcher {
        ConfigWatcher(path: path, started: started, restartable: restartable)
    }

    private init(path: String, started: Data, restartable: Bool) {
        timer = DispatchSource.makeTimerSource(queue: .main)
        // The last contents reported, so each change is logged once.
        var reported = started
        timer.setEventHandler {
            let current = FileManager.default.contents(atPath: path)
            switch Self.action(started: started, current: current) {
            case .none:
                reported = started
            case .restart where current != reported:
                reported = current ?? started
                if restartable {
                    print("[superlinear] \(path) changed; exiting so launchd restarts with the new config")
                    exit(0)
                }
                print("[superlinear] \(path) changed; restart superlinear to apply it")
            case .invalid(let reason) where current != reported:
                reported = current ?? Data()
                print("[superlinear] \(path) changed but cannot be used (\(reason)); keeping the current config")
            case .restart, .invalid:
                break
            }
        }
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval)
        timer.resume()
    }
}
