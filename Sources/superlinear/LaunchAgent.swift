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
            executablePath: stableExecutablePath(
                for: resolvingSymlinks(Bundle.main.executablePath ?? CommandLine.arguments[0]),
                fileExists: FileManager.default.isExecutableFile(atPath:)
            ),
            home: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    /// An absolute, symlink-free form of `path`.
    static func resolvingSymlinks(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// The path the agent should record for a resolved binary. A Homebrew
    /// binary lives under a versioned directory, such as
    /// `/opt/homebrew/Caskroom/superlinear/1.1.0/superlinear`, which an upgrade
    /// deletes; an agent pointing there would stop starting. So a Homebrew
    /// binary is recorded as its link in the prefix's `bin`, which upgrades
    /// repoint, when that link exists. Anything else is recorded as is.
    static func stableExecutablePath(
        for resolved: String, fileExists: (String) -> Bool
    ) -> String {
        for marker in ["/Caskroom/", "/Cellar/"] {
            guard let range = resolved.range(of: marker) else { continue }
            let name = URL(fileURLWithPath: resolved).lastPathComponent
            let link = "\(resolved[..<range.lowerBound])/bin/\(name)"
            return fileExists(link) ? link : resolved
        }
        return resolved
    }

    /// Whether a resolved binary path belongs to a Homebrew install rather than
    /// a local `make install`. Resolve first: the agent records Homebrew
    /// binaries by their `bin` link.
    static func isHomebrewBinary(_ path: String) -> Bool {
        path.contains("/Caskroom/") || path.contains("/Cellar/")
    }

    /// The local build an install from this binary should leave in place, if
    /// any. A local build takes precedence over Homebrew: when this binary is a
    /// Homebrew one and the installed agent runs a local build that still
    /// exists, replacing the agent would silently swap the daemon back. Both
    /// paths must already be resolved.
    static func devBinaryToKeep(
        installing: String, installed: String?, fileExists: (String) -> Bool
    ) -> String? {
        guard isHomebrewBinary(installing),
              let installed,
              installed != installing,
              !isHomebrewBinary(installed),
              fileExists(installed)
        else { return nil }
        return installed
    }

    func devBinaryToKeep() -> String? {
        Self.devBinaryToKeep(
            installing: Self.resolvingSymlinks(executablePath),
            installed: installedExecutablePath().map(Self.resolvingSymlinks),
            fileExists: FileManager.default.isExecutableFile(atPath:)
        )
    }

    /// The binary the agent on disk runs, or nil when none is installed.
    func installedExecutablePath() -> String? {
        guard let data = FileManager.default.contents(atPath: plistPath),
              let list = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any],
              let arguments = list["ProgramArguments"] as? [String]
        else { return nil }
        return arguments.first
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
