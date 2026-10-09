import Foundation

/// Keeps a Homebrew-installed daemon in step with the cask, without cask hooks.
///
/// Homebrew 7 deprecates cask flight blocks and sandboxes their replacements,
/// which cannot reach launchd or ~/Library/LaunchAgents. So the daemon watches
/// the binary it was started from instead. The agent runs Homebrew's stable
/// `bin/superlinear` link, which an upgrade repoints and an uninstall deletes:
///
/// - **Repointed:** the daemon exits, and launchd starts it again through the
///   link, on the new version. Agents in flight outlive the exit.
/// - **Gone for a while:** the cask was uninstalled, so the daemon removes its
///   own agent rather than leave launchd retrying a missing binary. The grace
///   period covers the moment mid-upgrade when the link does not exist.
///
/// Only a daemon that launchd started from a Homebrew binary watches. A local
/// build is reloaded by `make load`.
struct BinaryWatcher {
    static let interval: TimeInterval = 60
    static let uninstallGrace: TimeInterval = 5 * 60

    enum Action: Equatable {
        case none
        case restart
        case removeAgent
    }

    /// What to do, given the binary the daemon started as, what the link it was
    /// started through resolves to now (nil when it is gone), and since when it
    /// has been gone.
    static func action(started: String, current: String?, missingSince: Date?, now: Date) -> Action {
        if let current { return current == started ? .none : .restart }
        guard let missingSince else { return .none }
        return now.timeIntervalSince(missingSince) >= uninstallGrace ? .removeAgent : .none
    }

    /// The link to watch, or nil when this daemon should not watch: one not
    /// started by launchd as the agent, or not from a Homebrew binary.
    static func watchedPath(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard environment["XPC_SERVICE_NAME"] == LaunchAgent.label,
              let invoked = arguments.first, invoked.hasPrefix("/"),
              LaunchAgent.isHomebrewBinary(LaunchAgent.resolvingSymlinks(invoked))
        else { return nil }
        return invoked
    }

    private let path: String
    private let started: String
    private let timer: DispatchSourceTimer

    /// Starts watching `path` on the main queue.
    static func start(path: String) -> BinaryWatcher {
        BinaryWatcher(path: path)
    }

    private init(path: String) {
        self.path = path
        self.started = LaunchAgent.resolvingSymlinks(path)
        self.timer = DispatchSource.makeTimerSource(queue: .main)

        var missingSince: Date?
        let started = started
        timer.setEventHandler {
            let current = FileManager.default.fileExists(atPath: path)
                ? LaunchAgent.resolvingSymlinks(path) : nil
            if current == nil, missingSince == nil { missingSince = Date() }
            if current != nil { missingSince = nil }

            switch Self.action(started: started, current: current, missingSince: missingSince, now: Date()) {
            case .none:
                break
            case .restart:
                print("[superlinear] \(path) now points at \(current ?? "?"); exiting so launchd restarts the new version")
                exit(0)
            case .removeAgent:
                Self.removeAgent(path: path)
            }
        }
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval)
        timer.resume()
        print("[superlinear] Watching \(path) for Homebrew upgrades and uninstalls")
    }

    private static func removeAgent(path: String) {
        let agent = LaunchAgent(executablePath: path, home: Paths.home)
        // Leave an agent alone that something else installed meanwhile, such as
        // a local build.
        let installed = agent.installedExecutablePath()
        guard installed == nil || installed == path else {
            print("[superlinear] \(path) is gone and the agent now runs something else; exiting")
            exit(0)
        }
        print("[superlinear] \(path) has been gone for \(Int(uninstallGrace / 60)) minutes; removing the launch agent")
        do {
            try agent.removeFromRunningDaemon()
        } catch {
            print("[superlinear] Could not remove the launch agent: \(error.localizedDescription)")
        }
        exit(0)
    }
}
