import Foundation
import Testing
@testable import superlinear

// The daemon does what cask hooks would have: restarts onto an upgraded binary
// and removes its agent after an uninstall, but not in the moment mid-upgrade
// when the link is missing.
@Suite("BinaryWatcher")
struct BinaryWatcherTests {
    private let started = "/opt/homebrew/Caskroom/superlinear/1.2.0/superlinear"
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("An unchanged link needs nothing")
    func unchanged() {
        #expect(BinaryWatcher.action(started: started, current: started, missingSince: nil, now: now) == .none)
    }

    @Test("A link repointed by an upgrade restarts the daemon")
    func upgradeRestarts() {
        let upgraded = "/opt/homebrew/Caskroom/superlinear/1.3.0/superlinear"
        #expect(BinaryWatcher.action(started: started, current: upgraded, missingSince: nil, now: now) == .restart)
    }

    @Test("A briefly missing link is waited out")
    func briefGapWaits() {
        let since = now.addingTimeInterval(-60)
        #expect(BinaryWatcher.action(started: started, current: nil, missingSince: since, now: now) == .none)
    }

    @Test("A link gone past the grace period removes the agent")
    func uninstallRemovesAgent() {
        let since = now.addingTimeInterval(-BinaryWatcher.uninstallGrace)
        #expect(BinaryWatcher.action(started: started, current: nil, missingSince: since, now: now) == .removeAgent)
    }

    @Test("Only the launchd agent watches")
    func onlyTheAgentWatches() {
        let agentEnvironment = ["XPC_SERVICE_NAME": LaunchAgent.label]
        // A shell or another service runs it: no watching.
        #expect(BinaryWatcher.watchedPath(arguments: ["/usr/bin/true"], environment: [:]) == nil)
        #expect(BinaryWatcher.watchedPath(arguments: ["superlinear"], environment: agentEnvironment) == nil)
        // The agent, but not from Homebrew: a local build reloads with make.
        #expect(BinaryWatcher.watchedPath(
            arguments: ["/Users/example/.local/bin/superlinear"], environment: agentEnvironment
        ) == nil)
    }
}
