import Foundation

/// The workspace's Linear key in the environment of the Claude sessions that
/// superlinear starts, where `linctl` finds it. launchd gives the daemon no
/// `.envrc`, so without it a session reads no Linear, or the workspace of
/// `linctl`'s own default login. A repository's `.envrc`, loaded by
/// `direnv exec`, may still set its own.
///
/// The key goes only in the environment: never in a prompt, a log, an
/// argument or the state file.
enum LinearKey {
    /// The variables that `linctl` and other Linear tools read the key from.
    static let variables = ["LINCTL_API_KEY", "LINEAR_API_KEY"]

    /// `base` with the workspace's key in place of any key the daemon's own
    /// environment has.
    static func environment(_ base: [String: String], apiKey: String) -> [String: String] {
        base.merging(variables.map { ($0, apiKey) }, uniquingKeysWith: { $1 })
    }

    /// `base` without a Linear key, for a session that belongs to no
    /// workspace.
    static func withoutKey(_ base: [String: String]) -> [String: String] {
        base.filter { !variables.contains($0.key) }
    }

    /// The `linctl` commands that only read, for the sessions that only read.
    static let readTools = "Bash(linctl issue get:*),Bash(linctl issue list:*),Bash(linctl issue search:*)"

    /// What a prompt tells a session about reading Linear.
    static let promptLine = """
        You can read the workspace's Linear issues with `linctl issue get <identifier>`, `linctl issue list` and \
        `linctl issue search <words>`; the workspace's key is in your environment. Do not run other `linctl` commands.
        """
}
