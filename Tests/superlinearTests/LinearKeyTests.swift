import Foundation
import Testing
@testable import superlinear

@Suite("The workspace's Linear key in sessions")
struct LinearKeyTests {
    /// The daemon's own environment, with a key of another workspace.
    private let daemon = ["PATH": "/usr/bin", "LINCTL_API_KEY": "daemon-key"]

    @Test("An agent gets the workspace's key, not the daemon's")
    func agent() {
        let run = AgentRun(issueId: "spl-1", identifier: "SPL-1", branchName: "linear/spl-1", sessionId: "s1")
        let environment = AgentRunner(home: "/home", environment: daemon).launchEnvironment(for: run, apiKey: "workspace-key")
        #expect(environment["LINCTL_API_KEY"] == "workspace-key")
        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["ANTHROPIC_MODEL"] == AgentRunner.model)
    }

    @Test("A planning job gets the workspace's key, not the daemon's")
    func planning() {
        let environment = PlanningRunner(home: "/home", environment: daemon).launchEnvironment("s1", apiKey: "workspace-key")
        #expect(environment["LINCTL_API_KEY"] == "workspace-key")
        #expect(environment["SUPERLINEAR_STATUS_FILE"] == "/home/.local/share/superlinear/runs/planning-s1.status")
    }

    @Test("An answer session gets the workspace's key, not the daemon's")
    func answer() {
        let environment = CommentSessionRunner(home: "/home", environment: daemon).sessionEnvironment(apiKey: "workspace-key")
        #expect(environment["LINCTL_API_KEY"] == "workspace-key")
    }

    @Test("The usage-limit check, which belongs to no workspace, gets no key")
    func usageCheck() {
        #expect(LinearKey.withoutKey(daemon) == ["PATH": "/usr/bin"])
    }

    @Test("The planning job may read Linear issues with linctl, and its prompt says so")
    func planningTools() {
        #expect(PlanningRunner.allowedTools.hasSuffix(LinearKey.readTools))
        #expect(!PlanningRunner.allowedTools.contains("linctl issue update"))
    }
}
