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

// A local build takes precedence over Homebrew, so a Homebrew `install` must not
// point the agent back at itself while a local build is registered and present.
@Suite("LaunchAgent precedence")
struct LaunchAgentPrecedenceTests {
    private let brew = "/opt/homebrew/Caskroom/superlinear/1.1.0/superlinear"
    private let dev = "/Users/example/.local/bin/superlinear"

    @Test("Homebrew keeps an agent that runs an existing local build")
    func homebrewKeepsLocalBuild() {
        #expect(LaunchAgent.devBinaryToKeep(installing: brew, installed: dev, fileExists: { _ in true }) == dev)
    }

    @Test("Homebrew replaces an agent whose local build is gone")
    func homebrewReplacesMissingLocalBuild() {
        #expect(LaunchAgent.devBinaryToKeep(installing: brew, installed: dev, fileExists: { _ in false }) == nil)
    }

    @Test("Homebrew replaces an older Homebrew agent")
    func homebrewReplacesHomebrew() {
        let older = "/opt/homebrew/Caskroom/superlinear/1.0.1/superlinear"
        #expect(LaunchAgent.devBinaryToKeep(installing: brew, installed: older, fileExists: { _ in true }) == nil)
    }

    @Test("A local build always replaces the agent")
    func localBuildReplacesAnything() {
        #expect(LaunchAgent.devBinaryToKeep(installing: dev, installed: brew, fileExists: { _ in true }) == nil)
        #expect(LaunchAgent.devBinaryToKeep(installing: dev, installed: "/elsewhere/superlinear", fileExists: { _ in true }) == nil)
    }

    @Test("Nothing to keep on a first install")
    func firstInstall() {
        #expect(LaunchAgent.devBinaryToKeep(installing: brew, installed: nil, fileExists: { _ in true }) == nil)
    }
}

// The agent outlives upgrades, so it must not record a versioned directory that
// `brew upgrade` deletes.
@Suite("LaunchAgent stable path")
struct LaunchAgentStablePathTests {
    @Test("A cask binary is recorded by its bin link")
    func caskUsesBinLink() {
        let path = LaunchAgent.stableExecutablePath(
            for: "/opt/homebrew/Caskroom/superlinear/1.1.0/superlinear", fileExists: { _ in true }
        )
        #expect(path == "/opt/homebrew/bin/superlinear")
    }

    @Test("A formula binary is recorded by its bin link")
    func formulaUsesBinLink() {
        let path = LaunchAgent.stableExecutablePath(
            for: "/usr/local/Cellar/superlinear/1.1.0/bin/superlinear", fileExists: { _ in true }
        )
        #expect(path == "/usr/local/bin/superlinear")
    }

    @Test("Without a bin link, the versioned path is kept")
    func missingLinkKeepsResolved() {
        let resolved = "/opt/homebrew/Caskroom/superlinear/1.1.0/superlinear"
        #expect(LaunchAgent.stableExecutablePath(for: resolved, fileExists: { _ in false }) == resolved)
    }

    @Test("A local build is recorded as is")
    func localBuildUnchanged() {
        let dev = "/Users/example/.local/bin/superlinear"
        #expect(LaunchAgent.stableExecutablePath(for: dev, fileExists: { _ in true }) == dev)
    }
}
