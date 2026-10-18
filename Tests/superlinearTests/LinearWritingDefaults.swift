import Foundation
@testable import superlinear

/// What the fakes answer for the reads and writes they do not care about:
/// a team with Triage on, one label, and empty answers. The real client
/// implements every one of these, so these are for tests alone.
extension LinearWriting {
    func viewerId() async throws -> LinearUser.ID { "viewer" }

    func teamStates(id: LinearTeam.ID) async throws -> TeamStates {
        TeamStates(triageEnabled: true, states: [
            .init(id: "triage", type: .triage, position: 0), .init(id: "backlog", type: .backlog, position: 1),
            .init(id: "todo", type: .unstarted, position: 2),
        ])
    }

    func enableTriage(teamId: LinearTeam.ID) async throws {}
    func completeIssue(id: LinearIssue.ID) async throws -> Bool { true }
    func moveIssue(id: LinearIssue.ID, toFirst type: LinearStateType) async throws -> JSONValue { .null }

    func createComment(issueId: LinearIssue.ID, body: String) async throws -> CreatedComment {
        CreatedComment(id: "comment", url: nil, response: .null)
    }

    func updateComment(id: LinearComment.ID, body: String) async throws -> JSONValue { .null }

    func createReply(on target: CommentTarget, parentId: LinearComment.ID, body: String) async throws -> CreatedComment {
        CreatedComment(id: "reply", url: nil, response: .null)
    }
    func addLabel(issueId: LinearIssue.ID, labelId: LinearLabel.ID) async throws -> JSONValue { .null }
    func removeLabel(issueId: LinearIssue.ID, labelId: LinearLabel.ID) async throws -> JSONValue { .null }
    func proposalIssues(ids: [LinearIssue.ID]) async throws -> [ProposalIssueSnapshot] { [] }
}
