import Darwin
import Foundation
import Testing
@testable import superlinear

// `superlinear status` says which build polls and when, so a daemon still on
// an old build, or one that stopped, shows at once.
@Suite("Daemon and poll status")
struct DaemonInfoTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func temporaryHome() throws -> String {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: "\(home)/.local/share/superlinear", withIntermediateDirectories: true)
        return home
    }

    @Test("Durations read as how long ago or how soon")
    func relative() {
        #expect(StatusTime.relative(0) == "now")
        #expect(StatusTime.relative(-42) == "42s ago")
        #expect(StatusTime.relative(65) == "in 1m 5s")
        #expect(StatusTime.relative(-7_380) == "2h 3m ago")
        #expect(StatusTime.relative(90_000) == "in 1d 1h")
    }

    @Test("A poll says when it ended, whether it failed, and when the next is due")
    func pollLine() {
        let poll = PollRecord(endedAt: now.addingTimeInterval(-20), nextAt: now.addingTimeInterval(45))
        let line = poll.rendered(daemonRunning: true, now: now)
        #expect(line.hasPrefix("last poll ended "))
        #expect(line.contains("(20s ago) · next poll "))
        #expect(line.hasSuffix("(in 45s)"))

        var failed = poll
        failed.error = "offline"
        #expect(failed.rendered(daemonRunning: true, now: now).contains("(20s ago), failed: offline · "))
        #expect(poll.rendered(daemonRunning: false, now: now).hasSuffix("no next poll: the daemon is not running"))

        let polling = PollRecord(endedAt: now.addingTimeInterval(-80), nextAt: now.addingTimeInterval(-20))
        #expect(polling.rendered(daemonRunning: true, now: now).hasSuffix(" · polling since \(StatusTime.rendered(now.addingTimeInterval(-20), now: now))"))
        let slow = PollRecord(endedAt: now.addingTimeInterval(-1_000), nextAt: now.addingTimeInterval(-940))
        #expect(slow.rendered(daemonRunning: true, now: now).hasSuffix(", which is slow"))
    }

    @Test("A poll record survives the state file, and older state files load without one")
    func pollRecordRoundTrip() throws {
        var state = State()
        let poll = PollRecord(endedAt: now, nextAt: now.addingTimeInterval(60), error: "x")
        state.recordPoll(poll, workspace: "w")
        #expect(try State.decoded(from: state.encoded()).workspaces["w"]?.poll == poll)

        let legacy = #"{"workspaces":{"w":{"processedIssueIds":[],"lastPollTimestamp":"2023-11-14T22:13:20Z"}}}"#
        #expect(try State.decoded(from: Data(legacy.utf8)).workspaces["w"]?.poll == nil)
    }

    @Test("The daemon's line gives its pid, version, binary and start, or says it stopped")
    func daemonLine() {
        let info = DaemonInfo(
            pid: 42, version: "1.14.0+abc", executablePath: "/Users/x/.local/bin/superlinear",
            startedAt: now.addingTimeInterval(-90)
        )
        let running = info.rendered(running: true, binaryReplaced: false, now: now)
        #expect(running.hasPrefix("Daemon: pid 42, 1.14.0+abc from /Users/x/.local/bin/superlinear, started "))
        #expect(running.hasSuffix("(1m 30s ago)"))
        #expect(info.rendered(running: true, binaryReplaced: true, now: now)
            .contains("warning: /Users/x/.local/bin/superlinear has changed since the daemon started"))
        #expect(info.rendered(running: false, binaryReplaced: false, now: now)
            .hasPrefix("Daemon: not running; it last ran 1.14.0+abc from /Users/x/.local/bin/superlinear"))
    }

    @Test("The info file is read back; this process counts as running, a stopped one does not")
    func readsInfoFile() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let url = DaemonInfo.fileURL(home: home)
        let binary = "\(home)/superlinear"
        try Data("bin".utf8).write(to: URL(fileURLWithPath: binary))

        // Whole seconds, as the file keeps them.
        let startedAt = Date(timeIntervalSince1970: try #require(AgentRunner.startTime(of: getpid())).timeIntervalSince1970.rounded(.down))
        var info = DaemonInfo(
            pid: getpid(), version: "1.0.0", executablePath: binary, startedAt: startedAt,
            binaryIdentity: BinaryWatcher.identity(of: binary)
        )
        try info.write(to: url)
        var status = DaemonStatus.read(home: home)
        #expect(status.info == info)
        #expect(status.running)
        #expect(!status.binaryReplaced)

        // `make install` moves a new file over it.
        try Data("new".utf8).write(to: URL(fileURLWithPath: "\(binary).new"))
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: binary), withItemAt: URL(fileURLWithPath: "\(binary).new"))
        #expect(DaemonStatus.read(home: home).binaryReplaced)

        // The same pid, started at another time, is another process.
        info.startedAt = startedAt.addingTimeInterval(-3_600)
        try info.write(to: url)
        status = DaemonStatus.read(home: home)
        #expect(!status.running)
        #expect(status.rendered(now: now).hasPrefix("Daemon: not running;"))
    }

    @Test("Without an info file, the lock's pid tells whether an older daemon runs")
    func fallsBackToLock() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        #expect(DaemonStatus.read(home: home).rendered() == "Daemon: not running")
        try "\(getpid())\n".write(toFile: "\(home)/.local/share/superlinear/daemon.lock", atomically: true, encoding: .utf8)
        #expect(DaemonStatus.read(home: home).rendered().hasPrefix("Daemon: pid \(getpid()), started before"))
    }

    @Test("The footer gives the builds, then each workspace's polls in order")
    func footer() {
        let status = DaemonStatus(running: false)
        let poll = PollRecord(endedAt: now.addingTimeInterval(-5), nextAt: now.addingTimeInterval(55))
        let lines = status.footer(polls: [("iMox", poll), ("superlinear", nil)], now: now).split(separator: "\n")
        #expect(lines.count == 5)
        #expect(lines[0].hasPrefix("superlinear "))
        #expect(lines[1] == "Daemon: not running")
        #expect(lines[2] == "Polls")
        #expect(lines[3].hasPrefix("  iMox         last poll ended "))
        #expect(lines[4] == "  superlinear  not polled yet")
    }
}
