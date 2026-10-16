import Foundation

/// The reads and writes that applying proposals makes in Linear.
extension LinearClient: LinearWriting {
    func editableIssue(id: LinearIssue.ID) async throws -> EditableIssue {
        let issue = try await execute(
            .editableIssue, variables: ["id": id.rawValue], as: LinearQuery.EditableIssueData.self
        ).issue
        return EditableIssue(
            id: issue.id, identifier: issue.identifier, description: issue.description ?? "",
            updatedAt: issue.updatedAt, labels: issue.labels.nodes.map(\.name),
            stateType: issue.state.type, teamId: issue.team.id
        )
    }

    func openIssues(like title: String, teamId: LinearTeam.ID) async throws -> [IssueMatch] {
        let nodes = try await execute(
            .similarIssues, variables: ["term": title, "teamId": teamId.rawValue], as: LinearQuery.SimilarIssuesData.self
        ).searchIssues.nodes
        return nodes
            .filter { ![.completed, .canceled].contains($0.state.type) }
            .map { IssueMatch(id: $0.id, identifier: $0.identifier, title: $0.title) }
    }

    func labelId(named name: String, teamId: LinearTeam.ID) async throws -> LinearLabel.ID {
        let labels = try await execute(.labels, variables: ["name": name], as: LinearQuery.LabelsData.self).issueLabels.nodes
        // A workspace label serves every team; another team's does not.
        if let label = labels.first(where: { $0.team == nil || $0.team?.id == teamId }) {
            return label.id
        }
        let response = try await mutate(
            .createLabel, variables: ["teamId": teamId.rawValue, "name": name], field: "issueLabelCreate"
        )
        guard let id = response["issueLabelCreate"]?["issueLabel"]?["id"]?.stringValue else {
            throw LinearClientError.invalidResponse
        }
        return LinearLabel.ID(rawValue: id)
    }

    func createIssue(
        teamId: LinearTeam.ID, projectId: LinearProject.ID?, title: String, description: String, labelIds: [LinearLabel.ID]
    ) async throws -> JSONValue {
        var input: [String: Any] = [
            "teamId": teamId.rawValue, "title": title, "description": description, "labelIds": labelIds.map(\.rawValue),
        ]
        if let projectId { input["projectId"] = projectId.rawValue }
        return try await mutate(.createIssue, variables: ["input": input], field: "issueCreate")
    }

    func updateIssueDescription(id: LinearIssue.ID, description: String) async throws -> JSONValue {
        try await mutate(
            .editIssueDescription, variables: ["id": id.rawValue, "description": description], field: "issueUpdate"
        )
    }

    func closeIssue(id: LinearIssue.ID) async throws -> JSONValue {
        try await moveOrThrow(id: id, toFirst: "canceled")
    }

    func promoteIssue(id: LinearIssue.ID) async throws -> JSONValue {
        try await moveOrThrow(id: id, toFirst: "unstarted")
    }

    private func moveOrThrow(id: LinearIssue.ID, toFirst type: String) async throws -> JSONValue {
        // With nothing to skip, a move always happens or throws.
        guard let response = try await move(id: id.rawValue, toFirst: type) else { throw LinearClientError.invalidResponse }
        return response
    }

    func createRelation(issueId: LinearIssue.ID, relatedIssueId: LinearIssue.ID, type: String) async throws -> JSONValue {
        try await mutate(
            .createRelation,
            variables: ["issueId": issueId.rawValue, "relatedIssueId": relatedIssueId.rawValue, "type": type],
            field: "issueRelationCreate"
        )
    }

    func spec(of target: ProposalTarget) async throws -> SpecText {
        let node: LinearQuery.SpecNode
        switch target {
        case .project(let id, _):
            node = try await execute(.projectSpec, variables: ["id": id.rawValue], as: LinearQuery.ProjectSpecData.self).project
        case .document(let id, _):
            node = try await execute(.documentSpec, variables: ["id": id.rawValue], as: LinearQuery.DocumentSpecData.self).document
        case .issue, .team:
            throw ProposalError.unsupportedTarget(.changeSpec, target.kind)
        }
        return SpecText(content: node.content ?? "", updatedAt: node.updatedAt)
    }

    func updateSpec(of target: ProposalTarget, content: String) async throws -> JSONValue {
        switch target {
        case .project(let id, _):
            try await mutate(.changeProjectSpec, variables: ["id": id.rawValue, "content": content], field: "projectUpdate")
        case .document(let id, _):
            try await mutate(.changeDocumentSpec, variables: ["id": id.rawValue, "content": content], field: "documentUpdate")
        case .issue, .team:
            throw ProposalError.unsupportedTarget(.changeSpec, target.kind)
        }
    }

    func postProjectUpdate(projectId: LinearProject.ID, body: String, health: ProjectHealth?) async throws -> JSONValue {
        var variables: [String: Any] = ["projectId": projectId.rawValue, "body": body]
        if let health { variables["health"] = health.rawValue }
        return try await mutate(.postProjectUpdate, variables: variables, field: "projectUpdateCreate")
    }
}

/// The writes in Linear that a standup makes for the owner, besides applying
/// proposals.
protocol StandupWriting: LinearWriting {
    /// Moves the issue to its team's first completed state. Returns false
    /// when it was completed or canceled already.
    func completeIssue(id: LinearIssue.ID) async throws -> Bool
}

extension LinearClient: StandupWriting {
    func completeIssue(id: LinearIssue.ID) async throws -> Bool {
        try await completeIssue(id: id.rawValue)
    }
}
