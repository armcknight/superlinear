import Foundation

/// The reads and writes that proposals make in Linear.
extension LinearClient: LinearWriting {
    func viewerId() async throws -> LinearUser.ID {
        try await execute(.viewer, variables: [:], as: LinearQuery.ViewerData.self).viewer.id
    }

    func editableIssue(id: LinearIssue.ID) async throws -> EditableIssue {
        let issue = try await execute(
            .editableIssue, variables: [.id: id.rawValue], as: LinearQuery.EditableIssueData.self
        ).issue
        return EditableIssue(
            id: issue.id, identifier: issue.identifier, description: issue.description ?? "",
            updatedAt: issue.updatedAt, labels: issue.labels.nodes.map(\.name),
            stateType: issue.state.type, teamId: issue.team.id
        )
    }

    func openIssues(like title: String, teamId: LinearTeam.ID) async throws -> [IssueMatch] {
        let nodes = try await execute(
            .similarIssues, variables: [.term: title, .teamId: teamId.rawValue], as: LinearQuery.SimilarIssuesData.self
        ).searchIssues.nodes
        return nodes
            .filter { ![.completed, .canceled].contains($0.state.type) }
            .map { IssueMatch(id: $0.id, identifier: $0.identifier, title: $0.title) }
    }

    func labelId(named name: String, teamId: LinearTeam.ID) async throws -> LinearLabel.ID {
        let labels = try await execute(.labels, variables: [.name: name], as: LinearQuery.LabelsData.self).issueLabels.nodes
        // A workspace label serves every team; another team's does not.
        if let label = labels.first(where: { $0.team == nil || $0.team?.id == teamId }) {
            return label.id
        }
        let response = try await mutate(
            .createLabel, variables: [.teamId: teamId.rawValue, .name: name], field: .issueLabelCreate
        )
        guard let id = response[.issueLabelCreate]?[.issueLabel]?[.id]?.stringValue else {
            throw LinearClientError.invalidResponse
        }
        return LinearLabel.ID(rawValue: id)
    }

    func teamStates(id: LinearTeam.ID) async throws -> TeamStates {
        let team = try await execute(.teamStates, variables: [.id: id.rawValue], as: LinearQuery.TeamStatesData.self).team
        return TeamStates(
            triageEnabled: team.triageEnabled,
            states: team.states.nodes.map { TeamStates.State(id: $0.id, type: $0.type, position: $0.position) })
    }

    func enableTriage(teamId: LinearTeam.ID) async throws {
        try await mutate(.enableTriage, variables: [.id: teamId.rawValue], field: .teamUpdate)
    }

    func createIssue(
        teamId: LinearTeam.ID, projectId: LinearProject.ID?, title: String, description: String,
        labelIds: [LinearLabel.ID], stateId: LinearState.ID?
    ) async throws -> CreatedIssue {
        var input: [LinearVariable: Any] = [
            .teamId: teamId.rawValue, .title: title, .description: description, .labelIds: labelIds.map(\.rawValue),
        ]
        if let projectId { input[.projectId] = projectId.rawValue }
        if let stateId { input[.stateId] = stateId.rawValue }
        let response = try await mutate(.createIssue, variables: [.input: input], field: .issueCreate)
        guard let issue = response[.issueCreate]?[.issue], let id = issue[.id]?.stringValue,
              let identifier = issue[.identifier]?.stringValue
        else { throw LinearClientError.invalidResponse }
        return CreatedIssue(id: LinearIssue.ID(rawValue: id), identifier: identifier, url: issue[.url]?.stringValue, response: response)
    }

    func createComment(issueId: LinearIssue.ID, body: String) async throws -> CreatedComment {
        let response = try await mutate(
            .createComment, variables: [.issueId: issueId.rawValue, .body: body], field: .commentCreate)
        guard let comment = response[.commentCreate]?[.comment], let id = comment[.id]?.stringValue else {
            throw LinearClientError.invalidResponse
        }
        return CreatedComment(id: LinearComment.ID(rawValue: id), url: comment[.url]?.stringValue, response: response)
    }

    func createReply(on target: CommentTarget, parentId: LinearComment.ID, body: String) async throws -> CreatedComment {
        var input: [LinearVariable: Any] = [.parentId: parentId.rawValue, .body: body]
        switch target {
        case .issue(let id): input[.issueId] = id.rawValue
        case .document(let contentId): input[.documentContentId] = contentId
        }
        let response = try await mutate(.createReply, variables: [.input: input], field: .commentCreate)
        guard let comment = response[.commentCreate]?[.comment], let id = comment[.id]?.stringValue else {
            throw LinearClientError.invalidResponse
        }
        return CreatedComment(id: LinearComment.ID(rawValue: id), url: comment[.url]?.stringValue, response: response)
    }

    func updateComment(id: LinearComment.ID, body: String) async throws -> JSONValue {
        try await mutate(.updateComment, variables: [.id: id.rawValue, .body: body], field: .commentUpdate)
    }

    func addLabel(issueId: LinearIssue.ID, labelId: LinearLabel.ID) async throws -> JSONValue {
        try await mutate(.addLabel, variables: [.id: issueId.rawValue, .labelId: labelId.rawValue], field: .issueAddLabel)
    }

    func removeLabel(issueId: LinearIssue.ID, labelId: LinearLabel.ID) async throws -> JSONValue {
        try await mutate(.removeLabel, variables: [.id: issueId.rawValue, .labelId: labelId.rawValue], field: .issueRemoveLabel)
    }

    func proposalIssues(ids: [LinearIssue.ID]) async throws -> [ProposalIssueSnapshot] {
        var snapshots: [ProposalIssueSnapshot] = []
        let size = LinearQuery.proposalIssuesPageSize
        for start in stride(from: 0, to: ids.count, by: size) {
            let batch = ids[start..<min(start + size, ids.count)].map(\.rawValue)
            let nodes: [LinearQuery.ProposalIssueNode] = try await fetchAll(.proposalIssues, variables: [.ids: batch])
            snapshots += nodes.map(\.snapshot)
        }
        return snapshots
    }

    func updateIssueDescription(id: LinearIssue.ID, description: String) async throws -> JSONValue {
        try await mutate(
            .editIssueDescription, variables: [.id: id.rawValue, .description: description], field: .issueUpdate
        )
    }

    func closeIssue(id: LinearIssue.ID) async throws -> JSONValue {
        try await moveOrThrow(id: id, toFirst: .canceled)
    }

    func promoteIssue(id: LinearIssue.ID) async throws -> JSONValue {
        try await moveOrThrow(id: id, toFirst: .unstarted)
    }

    func completeIssue(id: LinearIssue.ID) async throws -> Bool {
        try await completeIssue(id: id.rawValue)
    }

    func moveIssue(id: LinearIssue.ID, toFirst type: LinearStateType) async throws -> JSONValue {
        try await moveOrThrow(id: id, toFirst: type)
    }

    private func moveOrThrow(id: LinearIssue.ID, toFirst type: LinearStateType) async throws -> JSONValue {
        // With nothing to skip, a move always happens or throws.
        guard let response = try await move(id: id.rawValue, toFirst: type.rawValue) else { throw LinearClientError.invalidResponse }
        return response
    }

    func createRelation(issueId: LinearIssue.ID, relatedIssueId: LinearIssue.ID, type: String) async throws -> JSONValue {
        try await mutate(
            .createRelation,
            variables: [.issueId: issueId.rawValue, .relatedIssueId: relatedIssueId.rawValue, .type: type],
            field: .issueRelationCreate
        )
    }

    func spec(of target: ProposalTarget) async throws -> SpecText {
        let node: LinearQuery.SpecNode
        switch target {
        case .project(let id, _):
            node = try await execute(.projectSpec, variables: [.id: id.rawValue], as: LinearQuery.ProjectSpecData.self).project
        case .document(let id, _):
            node = try await execute(.documentSpec, variables: [.id: id.rawValue], as: LinearQuery.DocumentSpecData.self).document
        case .issue, .team:
            throw ProposalError.unsupportedTarget(.changeSpec, target.kind)
        }
        return SpecText(content: node.content ?? "", updatedAt: node.updatedAt)
    }

    func updateSpec(of target: ProposalTarget, content: String) async throws -> JSONValue {
        switch target {
        case .project(let id, _):
            try await mutate(.changeProjectSpec, variables: [.id: id.rawValue, .content: content], field: .projectUpdate)
        case .document(let id, _):
            try await mutate(.changeDocumentSpec, variables: [.id: id.rawValue, .content: content], field: .documentUpdate)
        case .issue, .team:
            throw ProposalError.unsupportedTarget(.changeSpec, target.kind)
        }
    }

    func postProjectUpdate(projectId: LinearProject.ID, body: String) async throws -> JSONValue {
        try await mutate(
            .postProjectUpdate, variables: [.projectId: projectId.rawValue, .body: body], field: .projectUpdateCreate
        )
    }
}

/// The reads that answering the owner's comments makes in Linear.
extension LinearClient {
    /// The issues with these IDs, with their comments, oldest first. Issues
    /// Linear no longer has are absent.
    func issueComments(ids: [LinearIssue.ID]) async throws -> [IssueComments] {
        var issues: [IssueComments] = []
        let size = LinearQuery.issueCommentsPageSize
        for start in stride(from: 0, to: ids.count, by: size) {
            let batch = ids[start..<min(start + size, ids.count)].map(\.rawValue)
            let nodes: [LinearQuery.IssueCommentsNode] = try await fetchAll(.issueComments, variables: [.ids: batch])
            issues += nodes.map(\.issueComments)
        }
        return issues
    }

    func documentComments(id: LinearDocument.ID) async throws -> DocumentComments {
        try await execute(.documentComments, variables: [.id: id.rawValue], as: LinearQuery.DocumentCommentsData.self).documentComments
    }
}

/// The reads the planning job makes in Linear.
extension LinearClient: PlanningReading {
    func planningIssues(teamIds: [LinearTeam.ID]) async throws -> [PlanningIssue] {
        let nodes: [LinearQuery.PlanningIssueNode] = teamIds.isEmpty
            ? try await fetchAll(.planningIssues, variables: [:])
            : try await fetchAll(.planningIssuesInTeams, variables: [.teamIds: teamIds.map(\.rawValue)])
        return nodes.map(\.planningIssue)
    }

    func planningProjects(ids: [LinearProject.ID]) async throws -> [PlanningProject] {
        var projects: [PlanningProject] = []
        let size = LinearQuery.planningProjectsPageSize
        for start in stride(from: 0, to: ids.count, by: size) {
            let batch = ids[start..<min(start + size, ids.count)].map(\.rawValue)
            let nodes = try await execute(
                .planningProjects, variables: [.ids: batch], as: LinearQuery.PlanningProjectsData.self
            ).projects.nodes
            projects += nodes.map {
                PlanningProject(
                    id: $0.id, name: $0.name, content: $0.content ?? "", updatedAt: $0.updatedAt,
                    milestones: $0.projectMilestones.nodes.map { .init(name: $0.name) })
            }
        }
        return projects
    }

    func planningTeams(ids: [LinearTeam.ID]) async throws -> [PlanningTeam] {
        let teams = try await execute(.teams, variables: [:], as: LinearQuery.PlanningTeamsData.self).teams.nodes
        let wanted = Set(ids)
        return teams
            .filter { wanted.isEmpty || wanted.contains($0.id) }
            .map { PlanningTeam(id: $0.id, key: $0.key, name: $0.name) }
    }

    func completedIssues(teamIds: [LinearTeam.ID], after: Date) async throws -> [LinearIssue.Identifier] {
        var variables: [LinearVariable: Any] = [.after: [LinearVariable.gt: ISO8601DateFormatter().string(from: after)]]
        if !teamIds.isEmpty { variables[.teamIds] = teamIds.map(\.rawValue) }
        let nodes: [LinearQuery.CompletedIssueNode] = try await fetchAll(
            teamIds.isEmpty ? .completedIssuesSince : .completedIssuesSinceInTeams, variables: variables)
        return nodes.sorted { $0.completedAt < $1.completedAt }.map(\.identifier)
    }
}
