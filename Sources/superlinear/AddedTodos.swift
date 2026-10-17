import Foundation

/// `TODO` and `FIXME` lines a pull request added, from its diff, each
/// proposed as a new issue once it merges.
enum AddedTodos {
    /// The word that marks the line.
    enum Marker: String, CaseIterable, Sendable {
        case todo = "TODO"
        case fixme = "FIXME"
    }

    struct Todo: Equatable {
        var file: String
        var line: Int
        var marker: Marker
        /// The added line, trimmed.
        var text: String
    }

    static func diffArguments(number: PullRequest.Number) -> [String] {
        ["gh", "pr", "diff", "\(number)", "--color", "never"]
    }

    /// The added lines of a unified diff that hold a marker and name no issue,
    /// with their files and line numbers in the new version.
    static func parse(diff: String) -> [Todo] {
        let marker = /\b(TODO|FIXME)\b/
        // An issue identifier, such as `SPL-24`: a TODO naming one is tracked.
        let identifier = /\b[A-Z][A-Z0-9]*-[0-9]+\b/
        var todos: [Todo] = []
        var file: String?
        var line = 0
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.hasPrefix("+++ ") {
                let path = raw.dropFirst(4)
                file = path.hasPrefix("b/") ? String(path.dropFirst(2)) : (path == "/dev/null" ? nil : String(path))
            } else if raw.hasPrefix("--- ") || raw.hasPrefix("diff ") || raw.hasPrefix("index ") {
                continue
            } else if raw.hasPrefix("@@ ") {
                // @@ -a,b +c,d @@: the new version's lines start at c.
                let start = raw.split(separator: " ").first { $0.hasPrefix("+") }?
                    .dropFirst().split(separator: ",").first
                line = start.flatMap { Int($0) } ?? 0
            } else if raw.hasPrefix("+") {
                let text = raw.dropFirst().trimmingCharacters(in: .whitespaces)
                if let file, let match = text.firstMatch(of: marker), let found = Marker(rawValue: String(match.output.1)),
                   text.firstMatch(of: identifier) == nil {
                    todos.append(Todo(file: file, line: line, marker: found, text: text))
                }
                line += 1
            } else if raw.hasPrefix(" ") {
                line += 1
            }
        }
        return todos
    }

    static let maxTitleLength = 80

    /// The words after the marker, as the new issue's title, or a title
    /// naming the file when there are none.
    static func title(_ todo: Todo) -> String {
        let rest = todo.text.components(separatedBy: todo.marker.rawValue).dropFirst().joined(separator: todo.marker.rawValue)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":-–—()*/#").union(.whitespaces))
        let name = URL(fileURLWithPath: todo.file).lastPathComponent
        let title = rest.isEmpty ? "Resolve the \(todo.marker.rawValue) in \(name)" : "\(todo.marker.rawValue) in \(name): \(rest)"
        return title.count > maxTitleLength ? String(title.prefix(maxTitleLength - 1)) + "…" : title
    }

    static func draft(
        _ todo: Todo, pullRequest: PullRequest, agentIssue: LinearIssue.Identifier, issueId: LinearIssue.ID, teamId: LinearTeam.ID
    ) -> ProposalDraft {
        let description = """
            Pull request #\(pullRequest.number) for \(agentIssue) added this \(todo.marker.rawValue) at \
            `\(todo.file):\(todo.line)`:

            ```
            \(todo.text)
            ```
            """
        return ProposalDraft(
            payload: .createIssue(
                teamId: teamId, projectId: nil, title: title(todo), description: description, relatedIssueId: issueId
            ),
            target: .team(teamId),
            reason: "A merged pull request for \(agentIssue) left a \(todo.marker.rawValue)",
            source: ProposalSource(kind: .pullRequest, value: pullRequest.url, issue: agentIssue)
        )
    }
}
