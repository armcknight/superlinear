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

    @Test("A missing local build is left alone")
    func missingLocalBuildWaits() {
        let since = now.addingTimeInterval(-BinaryWatcher.uninstallGrace)
        #expect(BinaryWatcher.action(
            started: started, current: nil, missingSince: since, now: now, homebrew: false
        ) == .none)
    }

    @Test("Only the launchd agent watches, whether its binary is Homebrew's or a local build")
    func onlyTheAgentWatches() {
        let agentEnvironment = ["XPC_SERVICE_NAME": LaunchAgent.label]
        // A shell or another service runs it: no watching.
        #expect(BinaryWatcher.watchedPath(arguments: ["/usr/bin/true"], environment: [:]) == nil)
        #expect(BinaryWatcher.watchedPath(arguments: ["superlinear"], environment: agentEnvironment) == nil)
        #expect(BinaryWatcher.watchedPath(
            arguments: ["/Users/example/.local/bin/superlinear"], environment: agentEnvironment
        ) == "/Users/example/.local/bin/superlinear")
    }

    // `make install` moves a new file over the old one, at the same path.
    @Test("A file moved over the binary changes its identity; one left in place does not")
    func replacedFileChangesIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = "\(directory)/superlinear"
        try Data("one".utf8).write(to: URL(fileURLWithPath: path))
        let first = try #require(BinaryWatcher.identity(of: path))
        #expect(BinaryWatcher.identity(of: path) == first)

        try Data("two".utf8).write(to: URL(fileURLWithPath: "\(path).new"))
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: "\(path).new"))
        #expect(BinaryWatcher.identity(of: path) != first)
        #expect(BinaryWatcher.identity(of: "\(directory)/missing") == nil)
    }
}
