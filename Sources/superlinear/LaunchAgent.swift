import Foundation

enum LaunchAgentError: Error, LocalizedError {
    case launchctlFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .launchctlFailed(let command, let status):
            return "launchctl \(command) exited \(status)"
        }
    }
}

/// Renders and installs the launchd agent that runs the daemon at login.
///
/// This lives in the binary rather than in a checked-in plist because launchd
/// expands neither `~` nor `$HOME` inside a plist: every path has to be
/// absolute, so the file cannot be written once and shared. Generating it at
/// install time also means the agent points at whichever binary installed it —
/// a Homebrew one, or a locally built one — instead of a path baked in earlier.
struct LaunchAgent {
    static let label = "com.armcknight.superlinear"

    /// Absolute path to the `superlinear` binary the agent should run.
    let executablePath: String
    /// Absolute path to the user's home directory.
    let home: String

    init(executablePath: String, home: String) {
        self.executablePath = executablePath
        self.home = home
    }

    /// The agent for the currently running binary.
    static func current() -> LaunchAgent {
        LaunchAgent(
            executablePath: runningExecutablePath(),
            home: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    /// Resolves the running binary to an absolute, symlink-free path, so a
    /// Homebrew install records the real Cellar path rather than `bin/` shim.
    private static func runningExecutablePath() -> String {
        let raw = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
    }

    var plistPath: String { "\(home)/Library/LaunchAgents/\(Self.label).plist" }
    var logPath: String { "\(home)/.local/share/superlinear/daemon.log" }

    /// The agent definition. Built as a property list rather than by string
    /// interpolation so a path containing `&` or `<` cannot produce invalid XML.
    func propertyList() -> [String: Any] {
        [
            "Label": Self.label,
            "ProgramArguments": [executablePath],
            "EnvironmentVariables": [
                "PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": home,
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
            "WorkingDirectory": home,
            "ThrottleInterval": 30,
        ]
    }

    func plistData() throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: propertyList(), format: .xml, options: 0
        )
    }

    /// Writes the agent and loads it. Unloads any previous copy first, so this
    /// doubles as the reload path.
    func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            atPath: "\(home)/Library/LaunchAgents", withIntermediateDirectories: true
        )
        try fm.createDirectory(
            atPath: "\(home)/.local/share/superlinear", withIntermediateDirectories: true
        )
        try fm.createDirectory(
            atPath: "\(home)/.config/superlinear", withIntermediateDirectories: true
        )

        // Ignore the result: nothing is loaded on a first install.
        _ = Self.launchctl(["unload", plistPath])

        try plistData().write(to: URL(fileURLWithPath: plistPath), options: .atomic)

        let status = Self.launchctl(["load", "-w", plistPath])
        guard status == 0 else {
            throw LaunchAgentError.launchctlFailed("load", status)
        }
    }

    /// Unloads the agent and removes it. Succeeds when nothing is installed.
    func uninstall() throws {
        _ = Self.launchctl(["unload", "-w", plistPath])
        if FileManager.default.fileExists(atPath: plistPath) {
            try FileManager.default.removeItem(atPath: plistPath)
        }
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
