import Foundation

private let autonomousPrompt = """
You are working autonomously on a Linear issue. Do not ask for confirmation at any step — \
proceed through the entire workflow without pausing.

Your task:
1. Run /start to read the issue details, create a work plan, and set the issue to "In Progress".
2. Implement all the changes needed to complete the issue, following the plan from /start.
3. When implementation is complete, run /commit to stage and commit your changes.
4. Run /pr --autonomous to open a pull request without opening a browser, monitor CI until it passes, and address any review comments.

Work autonomously. Do not pause to ask questions. If you encounter ambiguity, make a reasonable \
decision and document it in the PR description.
"""

struct IssueProcessor: Sendable {
    let workspace: WorkspaceConfig

    func process(issue: LinearIssue) async throws {
        let repoPath = NSString(string: workspace.repoPath).expandingTildeInPath
        let promptFile = "/tmp/superlinear-\(issue.identifier).prompt"
        let logPath = issueLogPath(for: issue.identifier)

        log("Processing issue \(issue.identifier): \(issue.title)")
        log("  Branch: \(issue.branchName)")
        log("  Log: \(logPath)")

        try autonomousPrompt.write(toFile: promptFile, atomically: true, encoding: .utf8)

        try await Shell.run(
            command: "fish",
            arguments: [
                "-c",
                "work start --headless --prompt-file '\(promptFile)' --log-file '\(logPath)' '\(issue.branchName)'"
            ],
            workingDirectory: repoPath
        )

        log("  Claude completed for \(issue.identifier)")
    }

    private func issueLogPath(for identifier: String) -> String {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/superlinear/logs").path
        try? FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true)
        return (logsDir as NSString).appendingPathComponent("\(identifier).log")
    }

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] [\(workspace.name)] \(message)")
    }
}
