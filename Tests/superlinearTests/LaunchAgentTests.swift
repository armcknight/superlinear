import Foundation
import Testing
@testable import superlinear

// The agent is generated rather than checked in because launchd expands neither
// `~` nor `$HOME` inside a plist. Every path below therefore has to come out
// absolute — a relative one would load and then fail at runtime, silently.
@Suite("LaunchAgent rendering")
struct LaunchAgentTests {
    private let agent = LaunchAgent(
        executablePath: "/opt/homebrew/bin/superlinear",
        home: "/Users/example"
    )

    @Test("Every path is absolute and rooted in the given home")
    func pathsAreAbsolute() {
        #expect(agent.plistPath == "/Users/example/Library/LaunchAgents/com.armcknight.superlinear.plist")
        #expect(agent.logPath == "/Users/example/.local/share/superlinear/daemon.log")
    }

    @Test("The agent runs the binary it was told about")
    func runsTheGivenBinary() {
        let list = agent.propertyList()
        #expect(list["ProgramArguments"] as? [String] == ["/opt/homebrew/bin/superlinear"])
    }

    @Test("launchd keeps it alive and starts it at login")
    func daemonBehaviourFlags() {
        let list = agent.propertyList()
        #expect(list["Label"] as? String == "com.armcknight.superlinear")
        #expect(list["RunAtLoad"] as? Bool == true)
        #expect(list["KeepAlive"] as? Bool == true)
        #expect(list["ThrottleInterval"] as? Int == 30)
    }

    // A launchd agent inherits almost no environment. HOME matters because the
    // daemon resolves its config, state and per-issue logs relative to it, and
    // PATH matters because it shells out to fish, work and claude.
    @Test("HOME and PATH are set explicitly")
    func environmentIsExplicit() throws {
        let env = try #require(agent.propertyList()["EnvironmentVariables"] as? [String: String])
        #expect(env["HOME"] == "/Users/example")
        #expect(env["PATH"]?.contains("/opt/homebrew/bin") == true)
        #expect(env["PATH"]?.contains("/usr/bin") == true)
    }

    @Test("Both output streams go to the daemon log")
    func logsAreRedirected() {
        let list = agent.propertyList()
        #expect(list["StandardOutPath"] as? String == agent.logPath)
        #expect(list["StandardErrorPath"] as? String == agent.logPath)
    }

    @Test("It serializes to a plist launchd can parse back")
    func serializesToValidPlist() throws {
        let data = try agent.plistData()
        let parsed = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any]

        let restored = try #require(parsed)
        #expect(restored["Label"] as? String == "com.armcknight.superlinear")
        #expect(restored["ProgramArguments"] as? [String] == ["/opt/homebrew/bin/superlinear"])
        #expect(String(decoding: data, as: UTF8.self).hasPrefix("<?xml"))
    }

    // Built as a property list rather than by interpolation precisely so a path
    // containing XML metacharacters survives the round trip instead of producing
    // a malformed file.
    @Test("A path with XML metacharacters survives")
    func escapesAwkwardPaths() throws {
        let awkward = LaunchAgent(
            executablePath: "/Users/a&b/<bin>/superlinear", home: "/Users/a&b"
        )
        let data = try awkward.plistData()
        let parsed = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any]

        #expect(try #require(parsed)["ProgramArguments"] as? [String] == ["/Users/a&b/<bin>/superlinear"])
    }

    @Test("current() resolves a real home and a real binary")
    func currentUsesRealPaths() {
        let current = LaunchAgent.current()
        #expect(current.home.hasPrefix("/"))
        #expect(current.executablePath.hasPrefix("/"))
        #expect(current.plistPath.hasSuffix("com.armcknight.superlinear.plist"))
    }
}
