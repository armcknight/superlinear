import Foundation
import Testing
@testable import superlinear

// A config edit restarts the daemon only when the new file would start one,
// so a half-saved or broken edit leaves it running on the config it has.
@Suite("ConfigWatcher")
struct ConfigWatcherTests {
    private let started = Data(#"{"workspaces":[{"name":"w","apiKey":"k","repoPath":"~/r"}]}"#.utf8)

    @Test("Unchanged contents need nothing")
    func unchanged() {
        #expect(ConfigWatcher.action(started: started, current: started) == .none)
    }

    @Test("A valid change restarts the daemon")
    func validChangeRestarts() {
        let changed = Data(#"{"maxConcurrentAgents":5,"workspaces":[{"name":"w","apiKey":"k","repoPath":"~/r"}]}"#.utf8)
        #expect(ConfigWatcher.action(started: started, current: changed) == .restart)
    }

    @Test("A change that would not start a daemon is refused")
    func invalidChangesAreRefused() {
        for current in [
            Data("{\"workspaces\": [".utf8),   // mid-edit
            Data(#"{"workspaces":[]}"#.utf8),  // nothing to watch
            Data(#"{"workspaces":[{"name":"w"}]}"#.utf8),  // missing keys
        ] {
            guard case .invalid = ConfigWatcher.action(started: started, current: current) else {
                Issue.record("\(String(decoding: current, as: UTF8.self)) should be invalid")
                continue
            }
        }
    }

    @Test("A missing file is refused")
    func missingFile() {
        guard case .invalid = ConfigWatcher.action(started: started, current: nil) else {
            Issue.record("a missing file should be invalid")
            return
        }
    }
}
