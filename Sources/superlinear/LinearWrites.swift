import Foundation

/// The reads and writes that applying proposals makes in Linear.
extension LinearClient: LinearWriting {
    private static let editableIssueQuery = """
    query EditableIssue($id: String!) {
      issue(id: $id) {
        id
        identifier
        description
        updatedAt
        state { type }
        team { id }
        labels(first: 100) { nodes { name } }
      }
    }
    """

    func editableIssue(id: String) async throws -> EditableIssue {
        let issue = try await execute(Self.editableIssueQuery, variables: ["id": id], as: EditableIssueData.self).issue
        return EditableIssue(
            id: issue.id, identifier: issue.identifier, description: issue.description ?? "",
            updatedAt: issue.updatedAt, labels: issue.labels.nodes.map(\.name),
            stateType: issue.state.type, teamId: issue.team.id
        )
    }

    private static let searchQuery = """
    query SimilarIssues($term: String!, $teamId: String) {
      searchIssues(term: $term, teamId: $teamId, first: 25) {
        nodes { id identifier title state { type } }
      }
    }
    """

    func openIssues(like title: String, teamId: String) async throws -> [IssueMatch] {
        let nodes = try await execute(
            Self.searchQuery, variables: ["term": title, "teamId": teamId], as: SearchData.self
        ).searchIssues.nodes
        return nodes
            .filter { !["completed", "canceled"].contains($0.state.type) }
            .map { IssueMatch(id: $0.id, identifier: $0.identifier, title: $0.title) }
    }

    private static let labelQuery = """
    query Label($name: String!) {
      issueLabels(filter: { name: { eqIgnoreCase: $name } }, first: 50) {
        nodes { id team { id } }
      }
    }
    """

    private static let createLabelMutation = """
    mutation CreateLabel($teamId: String!, $name: String!) {
      issueLabelCreate(input: { teamId: $teamId, name: $name }) { success issueLabel { id } }
    }
    """

    func labelId(named name: String, teamId: String) async throws -> String {
        let labels = try await execute(Self.labelQuery, variables: ["name": name], as: LabelsData.self).issueLabels.nodes
        // A workspace label serves every team; another team's does not.
        if let label = labels.first(where: { $0.team == nil || $0.team?.id == teamId }) {
            return label.id
        }
        let response = try await mutate(
            Self.createLabelMutation, variables: ["teamId": teamId, "name": name], field: "issueLabelCreate"
        )
        guard let id = response["issueLabelCreate"]?["issueLabel"]?["id"]?.stringValue else {
            throw LinearClientError.invalidResponse
        }
        return id
    }

    private static let createIssueMutation = """
    mutation CreateIssue($input: IssueCreateInput!) {
      issueCreate(input: $input) { success issue { id identifier url } }
    }
    """

    func createIssue(
        teamId: String, projectId: String?, title: String, description: String, labelIds: [String]
    ) async throws -> JSONValue {
        var input: [String: Any] = ["teamId": teamId, "title": title, "description": description, "labelIds": labelIds]
        if let projectId { input["projectId"] = projectId }
        return try await mutate(Self.createIssueMutation, variables: ["input": input], field: "issueCreate")
    }

    private static let editIssueMutation = """
    mutation EditIssue($id: String!, $description: String!) {
      issueUpdate(id: $id, input: { description: $description }) { success issue { id identifier updatedAt } }
    }
    """

    func updateIssueDescription(id: String, description: String) async throws -> JSONValue {
        try await mutate(Self.editIssueMutation, variables: ["id": id, "description": description], field: "issueUpdate")
    }

    func closeIssue(id: String) async throws -> JSONValue {
        try await move(id: id, toFirstStateOfType: "canceled")
    }

    func promoteIssue(id: String) async throws -> JSONValue {
        try await move(id: id, toFirstStateOfType: "unstarted")
    }

    private static let teamStatesQuery = """
    query TeamStates($id: String!, $type: String!) {
      issue(id: $id) {
        team { states(filter: { type: { eq: $type } }) { nodes { id position } } }
      }
    }
    """

    private static let moveIssueMutation = """
    mutation MoveIssue($id: String!, $stateId: String!) {
      issueUpdate(id: $id, input: { stateId: $stateId }) { success issue { id identifier state { name type } } }
    }
    """

    private func move(id: String, toFirstStateOfType type: String) async throws -> JSONValue {
        let states = try await execute(
            Self.teamStatesQuery, variables: ["id": id, "type": type], as: TeamStatesData.self
        ).issue.team.states.nodes
        guard let state = states.min(by: { $0.position < $1.position }) else {
            throw LinearClientError.apiError(["The issue's team has no \(type) state"])
        }
        return try await mutate(Self.moveIssueMutation, variables: ["id": id, "stateId": state.id], field: "issueUpdate")
    }

    private static let relationMutation = """
    mutation Relate($issueId: String!, $relatedIssueId: String!, $type: IssueRelationType!) {
      issueRelationCreate(input: { issueId: $issueId, relatedIssueId: $relatedIssueId, type: $type }) {
        success
        issueRelation { id type }
      }
    }
    """

    func createRelation(issueId: String, relatedIssueId: String, type: String) async throws -> JSONValue {
        try await mutate(
            Self.relationMutation, variables: ["issueId": issueId, "relatedIssueId": relatedIssueId, "type": type],
            field: "issueRelationCreate"
        )
    }

    private static let projectSpecQuery = """
    query ProjectSpec($id: String!) { project(id: $id) { content updatedAt } }
    """

    private static let documentSpecQuery = """
    query DocumentSpec($id: String!) { document(id: $id) { content updatedAt } }
    """

    private static let updateProjectSpecMutation = """
    mutation ChangeProjectSpec($id: String!, $content: String!) {
      projectUpdate(id: $id, input: { content: $content }) { success project { id updatedAt } }
    }
    """

    private static let updateDocumentSpecMutation = """
    mutation ChangeDocument($id: String!, $content: String!) {
      documentUpdate(id: $id, input: { content: $content }) { success document { id updatedAt } }
    }
    """

    func spec(of target: ProposalTarget) async throws -> SpecText {
        let node: SpecNode
        switch target.kind {
        case .project:
            node = try await execute(Self.projectSpecQuery, variables: ["id": target.id], as: ProjectSpecData.self).project
        case .document:
            node = try await execute(Self.documentSpecQuery, variables: ["id": target.id], as: DocumentSpecData.self).document
        case .issue, .team:
            throw ProposalError.unsupportedTarget(.changeSpec, target.kind)
        }
        return SpecText(content: node.content ?? "", updatedAt: node.updatedAt)
    }

    func updateSpec(of target: ProposalTarget, content: String) async throws -> JSONValue {
        let variables: [String: Any] = ["id": target.id, "content": content]
        switch target.kind {
        case .project:
            return try await mutate(Self.updateProjectSpecMutation, variables: variables, field: "projectUpdate")
        case .document:
            return try await mutate(Self.updateDocumentSpecMutation, variables: variables, field: "documentUpdate")
        case .issue, .team:
            throw ProposalError.unsupportedTarget(.changeSpec, target.kind)
        }
    }

    private static let projectUpdateMutation = """
    mutation PostProjectUpdate($projectId: String!, $body: String!) {
      projectUpdateCreate(input: { projectId: $projectId, body: $body }) { success projectUpdate { id url } }
    }
    """

    func postProjectUpdate(projectId: String, body: String) async throws -> JSONValue {
        try await mutate(
            Self.projectUpdateMutation, variables: ["projectId": projectId, "body": body], field: "projectUpdateCreate"
        )
    }

    /// Runs a mutation whose result `field` reports `success`, failing when it
    /// does not.
    private func mutate(_ query: String, variables: [String: Any], field: String) async throws -> JSONValue {
        let (results, response) = try await executeKeepingResponse(query, variables: variables, as: [String: Success].self)
        guard results[field]?.success == true else { throw LinearClientError.invalidResponse }
        return response
    }

    private struct Success: Decodable {
        let success: Bool
    }

    private struct EditableIssueData: Decodable {
        let issue: Issue

        struct Issue: Decodable {
            let id: String
            let identifier: String
            let description: String?
            let updatedAt: Date
            let state: State
            let team: Team
            let labels: Labels
        }

        struct State: Decodable {
            let type: String
        }

        struct Team: Decodable {
            let id: String
        }

        struct Labels: Decodable {
            let nodes: [Label]
        }

        struct Label: Decodable {
            let name: String
        }
    }

    private struct SearchData: Decodable {
        let searchIssues: Results

        struct Results: Decodable {
            let nodes: [Node]
        }

        struct Node: Decodable {
            let id: String
            let identifier: String
            let title: String
            let state: State
        }

        struct State: Decodable {
            let type: String
        }
    }

    private struct LabelsData: Decodable {
        let issueLabels: Labels

        struct Labels: Decodable {
            let nodes: [Label]
        }

        struct Label: Decodable {
            let id: String
            let team: Team?
        }

        struct Team: Decodable {
            let id: String
        }
    }

    private struct TeamStatesData: Decodable {
        let issue: Issue

        struct Issue: Decodable {
            let team: Team
        }

        struct Team: Decodable {
            let states: States
        }

        struct States: Decodable {
            let nodes: [Node]
        }

        struct Node: Decodable {
            let id: String
            let position: Double
        }
    }

    private struct SpecNode: Decodable {
        let content: String?
        let updatedAt: Date
    }

    private struct ProjectSpecData: Decodable {
        let project: SpecNode
    }

    private struct DocumentSpecData: Decodable {
        let document: SpecNode
    }
}
