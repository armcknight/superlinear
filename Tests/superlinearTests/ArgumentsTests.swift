import Foundation
import Testing
@testable import superlinear

// An unknown word once fell through to running the daemon, so `status`, before
// this version had it, started a second daemon in the foreground.
@Suite("Command parsing")
struct ArgumentsTests {
    @Test("No arguments runs the daemon")
    func runsByDefault() {
        #expect(Command.parse([]) == .run(configPath: nil))
        #expect(Command.parse(["--config", "/c.json"]) == .run(configPath: "/c.json"))
    }

    @Test("Subcommands and their options")
    func subcommands() {
        #expect(Command.parse(["install"]) == .install(force: false))
        #expect(Command.parse(["install", "--force"]) == .install(force: true))
        #expect(Command.parse(["uninstall"]) == .uninstall)
        #expect(Command.parse(["status"]) == .status(configPath: nil, since: nil))
        #expect(Command.parse(["status", "--config", "/c.json"]) == .status(configPath: "/c.json", since: nil))
        #expect(Command.parse(["status", "--since", "7d", "--config", "/c.json"]) == .status(configPath: "/c.json", since: 7 * 24 * 60 * 60 as TimeInterval))
        #expect(Command.parse(["status", "--since", "soon"]) == .invalid("--since needs a duration such as 24h, 7d or 90m"))
        #expect(Command.parse(["standup"]) == .invalid("unknown command: standup"))
        #expect(Command.parse(["stats"]) == .stats(configPath: nil))
        #expect(Command.parse(["stats", "--config", "/c.json"]) == .stats(configPath: "/c.json"))
        #expect(Command.parse(["stats", "--since", "7d"]) == .invalid("unknown option for stats: --since"))
        #expect(Command.parse(["proposals"]) == .proposals(configPath: nil, workspace: nil))
        #expect(Command.parse(["proposals", "--workspace", "w", "--config", "/c.json"])
            == .proposals(configPath: "/c.json", workspace: "w"))
        #expect(Command.parse(["resume"]) == .resume)
        #expect(Command.parse(["resume", "--now"]) == .invalid("unknown option for resume: --now"))
        #expect(Command.parse(["--version"]) == .version)
        #expect(Command.parse(["-h"]) == .help)
    }

    @Test("Anything unknown is an error, not a daemon")
    func unknownIsInvalid() {
        for arguments in [["stat"], ["status", "--json"], ["stats", "--workspace", "w"], ["--verbose"], ["--config"], ["install", "--now"], ["uninstall", "x"], ["proposals", "--all"], ["proposals", "--workspace"]] {
            guard case .invalid = Command.parse(arguments) else {
                Issue.record("\(arguments) should be invalid")
                continue
            }
        }
    }
}

@Suite("Daemon lock")
struct DaemonLockTests {
    // flock locks belong to an open file description, so a second open in the
    // same process stands in for a second daemon.
    @Test("A second holder is refused and told who holds it")
    func secondHolderRefused() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).lock").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(DaemonLock.acquire(path: path) == .acquired)
        #expect(DaemonLock.acquire(path: path) == .held(by: getpid()))
    }
}
