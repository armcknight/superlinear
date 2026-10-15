import Foundation

/// Keeps the daemon in step with the binary launchd starts it from: a
/// Homebrew cask's, without cask hooks, or a local build's.
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
/// A local build is replaced in place by `make install`, which moves a new
/// file over the old: the daemon exits when the file at its path is no longer
/// the one it started from, and launchd starts the new one. A local build that
/// goes missing is left alone.
///
/// Only a daemon that launchd started as the agent watches. Switching between
/// a Homebrew binary and a local build takes `superlinear install` from the
/// other one, as the agent names a single binary.
struct BinaryWatcher {
    static let interval: TimeInterval = 60
    static let uninstallGrace: TimeInterval = 5 * 60

    enum Action: Equatable {
        case none
        case restart
        case removeAgent
    }

    /// What to do, given the identity of the binary the daemon started as, the
    /// identity of what its path holds now (nil when it is gone), and since
    /// when it has been gone. Only a Homebrew binary's absence removes the
    /// agent.
    static func action(
        started: String, current: String?, missingSince: Date?, now: Date, homebrew: Bool = true
    ) -> Action {
        if let current { return current == started ? .none : .restart }
        guard homebrew, let missingSince else { return .none }
        return now.timeIntervalSince(missingSince) >= uninstallGrace ? .removeAgent : .none
    }

    /// The path to watch, or nil when this daemon should not watch: one not
    /// started by launchd as the agent.
    static func watchedPath(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard environment["XPC_SERVICE_NAME"] == LaunchAgent.label,
              let invoked = arguments.first, invoked.hasPrefix("/")
        else { return nil }
        return invoked
    }

    /// What `path` resolves to, and the file there, or nil when it is gone. An
    /// upgrade repoints a Homebrew link; `make install` moves a new file, with
    /// a new inode, to the same path.
    static func identity(of path: String) -> String? {
        let resolved = LaunchAgent.resolvingSymlinks(path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
              let inode = attributes[.systemFileNumber] as? NSNumber
        else { return nil }
        return "\(resolved)#\(inode)"
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
        self.started = Self.identity(of: path) ?? LaunchAgent.resolvingSymlinks(path)
        self.timer = DispatchSource.makeTimerSource(queue: .main)

        var missingSince: Date?
        let started = started
        let homebrew = LaunchAgent.isHomebrewBinary(LaunchAgent.resolvingSymlinks(path))
        timer.setEventHandler {
            let current = Self.identity(of: path)
            if current == nil, missingSince == nil { missingSince = Date() }
            if current != nil { missingSince = nil }

            switch Self.action(
                started: started, current: current, missingSince: missingSince, now: Date(), homebrew: homebrew
            ) {
            case .none:
                break
            case .restart:
                let resolved = LaunchAgent.resolvingSymlinks(path)
                let what = homebrew ? "now points at \(resolved)" : "was replaced"
                print("[superlinear] \(path) \(what); exiting so launchd restarts the new version")
                exit(0)
            case .removeAgent:
                Self.removeAgent(path: path)
            }
        }
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval)
        timer.resume()
        print("[superlinear] Watching \(path) for \(homebrew ? "Homebrew upgrades and uninstalls" : "a new build")")
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
