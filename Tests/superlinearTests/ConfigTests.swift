import Foundation
import Testing
@testable import superlinear

@Suite("Config decoding")
struct ConfigTests {
    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    @Test("Optional keys fall back to their documented defaults")
    func optionalKeysDefault() throws {
        let config = try decode("""
        {"workspaces": [{"name": "w", "apiKey": "k", "repoPath": "~/r"}]}
        """)

        let workspace = try #require(config.workspaces.first)
        #expect(workspace.teamIds == [])
        #expect(workspace.pollIntervalSeconds == 60)
    }

    @Test("The agent limit defaults, and cannot go below one")
    func agentLimit() throws {
        let workspaces = #""workspaces": [{"name": "w", "apiKey": "k", "repoPath": "~/r"}]"#
        #expect(try decode("{\(workspaces)}").maxConcurrentAgents == Config.defaultMaxConcurrentAgents)
        #expect(try decode("{\(workspaces), \"maxConcurrentAgents\": 5}").maxConcurrentAgents == 5)
        #expect(try decode("{\(workspaces), \"maxConcurrentAgents\": 0}").maxConcurrentAgents == 1)
    }

    @Test("Explicit values win over the defaults")
    func explicitValuesWin() throws {
        let config = try decode("""
        {"workspaces": [{
          "name": "w", "apiKey": "k", "repoPath": "~/r",
          "teamIds": ["a", "b"], "pollIntervalSeconds": 5
        }]}
        """)

        let workspace = try #require(config.workspaces.first)
        #expect(workspace.teamIds == ["a", "b"])
        #expect(workspace.pollIntervalSeconds == 5)
    }

    // A null is not the same as an absent key: decodeIfPresent returns nil for
    // both, so both must land on the default rather than failing to decode.
    @Test("Null optional keys fall back too")
    func nullOptionalKeys() throws {
        let config = try decode("""
        {"workspaces": [{
          "name": "w", "apiKey": "k", "repoPath": "~/r",
          "teamIds": null, "pollIntervalSeconds": null
        }]}
        """)

        let workspace = try #require(config.workspaces.first)
        #expect(workspace.teamIds == [])
        #expect(workspace.pollIntervalSeconds == 60)
    }

    @Test("A missing required key is an error, not a default")
    func missingRequiredKeyThrows() {
        #expect(throws: DecodingError.self) {
            _ = try decode("""
            {"workspaces": [{"name": "w", "repoPath": "~/r"}]}
            """)
        }
    }

    @Test("Several workspaces decode in order")
    func multipleWorkspaces() throws {
        let config = try decode("""
        {"workspaces": [
          {"name": "one", "apiKey": "k1", "repoPath": "~/a"},
          {"name": "two", "apiKey": "k2", "repoPath": "~/b"}
        ]}
        """)

        #expect(config.workspaces.map(\.name) == ["one", "two"])
    }

    @Test("An empty workspace list decodes, and main.swift exits on it")
    func emptyWorkspaces() throws {
        #expect(try decode(#"{"workspaces": []}"#).workspaces.isEmpty)
    }

    @Test("load(from:) reads a file off disk")
    func loadFromPath() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("superlinear-config-\(UUID().uuidString).json")
        try #"{"workspaces": [{"name": "w", "apiKey": "k", "repoPath": "~/r"}]}"#
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let config = try Config.load(from: url.path)
        #expect(config.workspaces.count == 1)
    }

    @Test("load(from:) throws when the file is absent")
    func loadMissingPathThrows() {
        #expect(throws: (any Error).self) {
            _ = try Config.load(from: "/nonexistent/superlinear/config.json")
        }
    }

    @Test("Selection keys default to new mode, Todo as ready, and the usual human labels")
    func selectionDefaults() throws {
        let workspace = try #require(try decode("""
        {"workspaces": [{"name": "w", "apiKey": "k", "repoPath": "~/r"}]}
        """).workspaces.first)
        #expect(workspace.selection == .new)
        #expect(workspace.readyStates == [.unstarted])
        #expect(workspace.humanLabels == ["Needs human", "Spike"])
        #expect(workspace.startableStates == [.backlog, .unstarted])
    }

    @Test("Ready mode starts from its configured ready states")
    func readySelection() throws {
        let workspace = try #require(try decode("""
        {"workspaces": [{"name": "w", "apiKey": "k", "repoPath": "~/r",
          "selection": "ready", "readyStates": ["unstarted", "backlog"], "humanLabels": []}]}
        """).workspaces.first)
        #expect(workspace.selection == .ready)
        #expect(workspace.startableStates == [.unstarted, .backlog])
        #expect(workspace.humanLabels.isEmpty)
    }

    @Test("An unknown selection is an error, not a silent default")
    func unknownSelectionThrows() {
        #expect(throws: DecodingError.self) {
            _ = try decode("""
            {"workspaces": [{"name": "w", "apiKey": "k", "repoPath": "~/r", "selection": "all"}]}
            """)
        }
    }

    @Test("A ready state that is not a Linear state type is an error")
    func unknownReadyStateThrows() {
        #expect(throws: DecodingError.self) {
            _ = try decode("""
            {"workspaces": [{"name": "w", "apiKey": "k", "repoPath": "~/r", "readyStates": ["Todo"]}]}
            """)
        }
    }
}
