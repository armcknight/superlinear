import Foundation

enum Paths {
    /// `$HOME` when set — launchd sets it from the agent, and a shell always
    /// does — or else the account's home directory. Honouring `$HOME` lets a
    /// test run the daemon against a scratch directory instead of the real one.
    static var home: String {
        ProcessInfo.processInfo.environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    }
}
