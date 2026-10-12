import Foundation
import Testing
@testable import superlinear

// An unknown word once fell through to running the daemon, so a command this
// version lacks started a second daemon in the foreground.
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
        #expect(Command.parse(["--version"]) == .version)
        #expect(Command.parse(["-h"]) == .help)
    }

    @Test("Anything unknown is an error, not a daemon")
    func unknownIsInvalid() {
        for arguments in [["status"], ["--verbose"], ["--config"], ["install", "--now"], ["uninstall", "x"]] {
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
