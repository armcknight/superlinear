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

    func process(issue: LinearIssue) async throws -> Bool {
        let branchName = issue.branchName
        let repoPath = NSString(string: workspace.repoPath).expandingTildeInPath
        let worktreePath = (repoPath as NSString).appendingPathComponent("worktrees/\(branchName)")

        log("Processing issue \(issue.identifier): \(issue.title)")
        log("  Branch: \(branchName)")
        log("  Worktree: \(worktreePath)")

        try await createWorktree(branchName: branchName, repoPath: repoPath, worktreePath: worktreePath)
        try symlinkEnvFiles(repoPath: repoPath, worktreePath: worktreePath)
        let makeInitFailed = await runMakeInit(worktreePath: worktreePath)
        try launchClaudeSession(issue: issue, branchName: branchName, worktreePath: worktreePath)

        return makeInitFailed
    }

    private func createWorktree(branchName: String, repoPath: String, worktreePath: String) async throws {
        // Create parent directory for nested branch paths (e.g. linear/arm-123-foo)
        let worktreeParent = (worktreePath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: worktreeParent,
            withIntermediateDirectories: true
        )

        // Check if worktree already exists
        if FileManager.default.fileExists(atPath: worktreePath) {
            log("  Worktree already exists, reusing")
            return
        }

        try await Shell.run(
            command: "git",
            arguments: ["-C", repoPath, "worktree", "add", worktreePath, "-b", branchName],
            workingDirectory: repoPath
        )
        log("  Worktree created")
    }

    private func symlinkEnvFiles(repoPath: String, worktreePath: String) throws {
        let candidates = [".env", ".envrc", "fastlane/.env"]
        for relative in candidates {
            let source = (repoPath as NSString).appendingPathComponent(relative)
            let dest = (worktreePath as NSString).appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: source) else { continue }

            // Create parent dir for nested paths (e.g. fastlane/.env)
            let destParent = (dest as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: destParent, withIntermediateDirectories: true)

            // Remove existing link if present
            try? FileManager.default.removeItem(atPath: dest)
            try FileManager.default.createSymbolicLink(atPath: dest, withDestinationPath: source)
        }
        log("  Environment files symlinked")
    }

    private func runMakeInit(worktreePath: String) async -> Bool {
        let makefile = (worktreePath as NSString).appendingPathComponent("Makefile")
        guard FileManager.default.fileExists(atPath: makefile) else {
            log("  No Makefile found, skipping make init")
            return false
        }
        do {
            try await Shell.run(command: "make", arguments: ["init"], workingDirectory: worktreePath)
            log("  make init succeeded")
            return false
        } catch {
            log("  make init failed: \(error) — continuing anyway")
            return true
        }
    }

    private func launchClaudeSession(issue: LinearIssue, branchName: String, worktreePath: String) throws {
        let sessionName = tmuxSessionName(for: branchName)
        let logPath = issueLogPath(for: issue.identifier)

        // Write prompt to a file to avoid quoting/newline issues when embedding in a shell command
        let promptFile = "/tmp/superlinear-\(sessionName).prompt"
        try autonomousPrompt.write(toFile: promptFile, atomically: true, encoding: .utf8)

        // -p runs headless (skips the --dangerously-skip-permissions confirmation dialog)
        // tee logs output so it's readable after the session closes
        let command = "claude -p --dangerously-skip-permissions < '\(promptFile)' 2>&1 | tee '\(logPath)'"

        try Shell.runDetachedCommand(
            "tmux",
            arguments: [
                "new-session", "-d",
                "-s", sessionName,
                "-c", worktreePath,
                command
            ],
            workingDirectory: worktreePath
        )
        log("  Claude session started: tmux attach -t \(sessionName)")
        log("  Log: tail -f \(logPath)")
    }

    private func issueLogPath(for identifier: String) -> String {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/superlinear/logs").path
        try? FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true)
        return (logsDir as NSString).appendingPathComponent("\(identifier).log")
    }

    private func tmuxSessionName(for branchName: String) -> String {
        let sanitized = branchName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let prefix = "superlinear_"
        let maxLen = 50 - prefix.count
        return prefix + String(sanitized.prefix(maxLen))
    }

    private func claudeExecutablePath() -> String { "claude" }

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] [\(workspace.name)] \(message)")
    }
}
