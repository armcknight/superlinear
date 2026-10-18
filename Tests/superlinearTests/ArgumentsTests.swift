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
        #expect(Command.parse(["status"]) == .status(configPath: nil, filter: StatusFilter()))
        #expect(Command.parse(["status", "--config", "/c.json"]) == .status(configPath: "/c.json", filter: StatusFilter()))
        #expect(Command.parse(["stats"]) == .stats(configPath: nil))
        #expect(Command.parse(["stats", "--config", "/c.json"]) == .stats(configPath: "/c.json"))
        #expect(Command.parse(["proposals"]) == .proposals(configPath: nil, workspace: nil))
        #expect(Command.parse(["proposals", "--workspace", "w", "--config", "/c.json"])
            == .proposals(configPath: "/c.json", workspace: "w"))
        #expect(Command.parse(["resume"]) == .resume)
        #expect(Command.parse(["resume", "--now"]) == .invalid("unknown option for resume: --now"))
        #expect(Command.parse(["--version"]) == .version)
        #expect(Command.parse(["-h"]) == .help)
    }

    @Test("status takes sections and workspaces, comma-separated or repeated")
    func statusFilter() {
        #expect(Command.parse(["status", "--status", "running,blocked", "--status", "stale"])
            == .status(configPath: nil, filter: StatusFilter(sections: [.task(.running), .task(.blocked), .stale])))
        #expect(Command.parse(["status", "--status", "awaiting-review, completed"])
            == .status(configPath: nil, filter: StatusFilter(sections: [.awaitingReview, .task(.completed)])))
        #expect(Command.parse(["status", "--workspace", "a,b", "--workspace", "c", "--config", "/c.json"])
            == .status(configPath: "/c.json", filter: StatusFilter(workspaces: ["a", "b", "c"])))
        #expect(Command.parse(["status", "--status", "closed", "--workspace", "a"])
            == .status(configPath: nil, filter: StatusFilter(sections: [.task(.closed)], workspaces: ["a"])))
    }

    @Test("An unknown status names the ones there are")
    func unknownStatus() {
        guard case .invalid(let message) = Command.parse(["status", "--status", "running,done"]) else {
            Issue.record("should be invalid")
            return
        }
        #expect(message.hasPrefix("unknown status: done. Statuses: awaiting-review, drafts, running, "))
        #expect(message.hasSuffix(", completed, closed, stale"))
    }

    @Test("Anything unknown is an error, not a daemon")
    func unknownIsInvalid() {
        for arguments in [["stat"], ["status", "--json"], ["stats", "--workspace", "w"], ["stats", "--status", "running"], ["--verbose"], ["--config"], ["install", "--now"], ["uninstall", "x"], ["proposals", "--all"], ["proposals", "--workspace"], ["status", "--status"], ["status", "--status", ","], ["status", "--workspace"]] {
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
