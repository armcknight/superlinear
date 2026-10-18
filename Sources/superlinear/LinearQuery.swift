import Foundation

/// Every GraphQL query and mutation superlinear sends to Linear. The types
/// below the cases are the data each one answers with.
enum LinearQuery: CaseIterable, Sendable {
    /// Backlog and unstarted issues created since a time, in any team.
    case newIssues
    /// Backlog and unstarted issues created since a time, in some teams.
    case newIssuesInTeams
    /// Issues in some state types, in any team.
    case readyIssues
    /// Issues in some state types, in some teams.
    case readyIssuesInTeams
    /// The issues with some IDs, as candidates for an agent.
    case candidatesById
    /// The issues with some IDs, as `superlinear status` reports them.
    case issuesById
    /// Issues in a started state, in any team.
    case startedIssues
    /// Issues in a started state, in some teams.
    case startedIssuesInTeams
    /// The issues with some numbers in teams with some keys.
    case issuesByNumber
    /// An issue's state type, and its team's states of one type.
    case issueState
    case moveIssue
    case linkURL
    case attachments
    /// An issue as an edit needs it: its text, labels and when it changed.
    case editableIssue
    /// Linear's search for issues like a title, in a team.
    case similarIssues
    /// The labels with a name, in every team and the workspace.
    case labels
    case createLabel
    case createIssue
    case editIssueDescription
    case createRelation
    case projectSpec
    case documentSpec
    case changeProjectSpec
    case changeDocumentSpec
    case postProjectUpdate
    /// Open issues with what the planning job looks at, in any team.
    case planningIssues
    /// Open issues with what the planning job looks at, in some teams.
    case planningIssuesInTeams
    /// The projects with some IDs, with their descriptions and milestones.
    case planningProjects
    /// Issues in the watched teams completed after a time, for the planning
    /// job's trigger and its context.
    case completedIssuesSince
    case completedIssuesSinceInTeams
    case teams
    /// The workspace's first team, for proposals that belong to no issue.
    case firstTeam
    /// The user the API key belongs to.
    case viewer
    /// A team's workflow states, and whether Triage is on.
    case teamStates
    case enableTriage
    case createComment
    case updateComment
    case addLabel
    case removeLabel
    /// The issues proposals wait on, with their comments and reactions.
    case proposalIssues

    var text: String {
        switch self {
        case .newIssues: """
            query NewIssues($after: DateComparator, $cursor: String) {
              issues(
                filter: {
                  createdAt: $after
                  state: { type: { in: ["backlog", "unstarted"] } }
                }
                orderBy: createdAt
                first: 25
                after: $cursor
              ) {
            \(Self.candidateFields)
              }
            }
            """
        case .newIssuesInTeams: """
            query NewIssues($after: DateComparator, $teamIds: [ID!], $cursor: String) {
              issues(
                filter: {
                  createdAt: $after
                  team: { id: { in: $teamIds } }
                  state: { type: { in: ["backlog", "unstarted"] } }
                }
                orderBy: createdAt
                first: 25
                after: $cursor
              ) {
            \(Self.candidateFields)
              }
            }
            """
        case .readyIssues: """
            query ReadyIssues($states: [String!], $cursor: String) {
              issues(filter: { state: { type: { in: $states } } }, first: 25, after: $cursor) {
            \(Self.candidateFields)
              }
            }
            """
        case .readyIssuesInTeams: """
            query ReadyIssues($states: [String!], $teamIds: [ID!], $cursor: String) {
              issues(
                filter: { state: { type: { in: $states } }, team: { id: { in: $teamIds } } }
                first: 25
                after: $cursor
              ) {
            \(Self.candidateFields)
              }
            }
            """
        case .candidatesById: """
            query CandidatesById($ids: [ID!], $cursor: String) {
              issues(filter: { id: { in: $ids } }, first: 25, after: $cursor) {
            \(Self.candidateFields)
              }
            }
            """
        // Archived issues are left out, as they are by default, so issues long
        // since finished drop out of the status report on their own.
        case .issuesById: """
            query IssuesById($ids: [ID!], $cursor: String) {
              issues(
                filter: { id: { in: $ids } }
                first: 50
                after: $cursor
              ) {
                nodes {
                  id
                  identifier
                  title
                  branchName
                  state { name type }
                }
                pageInfo { hasNextPage endCursor }
              }
            }
            """
        case .startedIssues: """
            query StartedIssues($cursor: String) {
              issues(filter: { state: { type: { eq: "started" } } }, first: 50, after: $cursor) {
            \(Self.startedIssueFields)
              }
            }
            """
        case .startedIssuesInTeams: """
            query StartedIssues($teamIds: [ID!], $cursor: String) {
              issues(
                filter: { state: { type: { eq: "started" } }, team: { id: { in: $teamIds } } }
                first: 50
                after: $cursor
              ) {
            \(Self.startedIssueFields)
              }
            }
            """
        case .issuesByNumber: """
            query IssuesByNumber($numbers: [Float!], $keys: [String!], $cursor: String) {
              issues(
                filter: { number: { in: $numbers }, team: { key: { in: $keys } } }
                first: 50
                after: $cursor
              ) {
            \(Self.startedIssueFields)
              }
            }
            """
        case .issueState: """
            query IssueState($id: String!, $type: String!) {
              issue(id: $id) {
                state { type }
                team {
                  states(filter: { type: { eq: $type } }) {
                    nodes { id position }
                  }
                }
              }
            }
            """
        case .moveIssue: """
            mutation MoveIssue($id: String!, $stateId: String!) {
              issueUpdate(id: $id, input: { stateId: $stateId }) { success issue { id identifier state { name type } } }
            }
            """
        case .linkURL: """
            mutation LinkPullRequest($issueId: String!, $url: String!, $title: String) {
              attachmentLinkURL(issueId: $issueId, url: $url, title: $title) { success }
            }
            """
        case .attachments: """
            query IssueAttachments($id: String!) {
              issue(id: $id) { attachments(first: 250) { nodes { url } } }
            }
            """
        case .editableIssue: """
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
        case .similarIssues: """
            query SimilarIssues($term: String!, $teamId: String) {
              searchIssues(term: $term, teamId: $teamId, first: 25) {
                nodes { id identifier title state { type } }
              }
            }
            """
        case .labels: """
            query Label($name: String!) {
              issueLabels(filter: { name: { eqIgnoreCase: $name } }, first: 50) {
                nodes { id team { id } }
              }
            }
            """
        case .createLabel: """
            mutation CreateLabel($teamId: String!, $name: String!) {
              issueLabelCreate(input: { teamId: $teamId, name: $name }) { success issueLabel { id } }
            }
            """
        case .createIssue: """
            mutation CreateIssue($input: IssueCreateInput!) {
              issueCreate(input: $input) { success issue { id identifier url } }
            }
            """
        case .editIssueDescription: """
            mutation EditIssue($id: String!, $description: String!) {
              issueUpdate(id: $id, input: { description: $description }) { success issue { id identifier updatedAt } }
            }
            """
        case .createRelation: """
            mutation Relate($issueId: String!, $relatedIssueId: String!, $type: IssueRelationType!) {
              issueRelationCreate(input: { issueId: $issueId, relatedIssueId: $relatedIssueId, type: $type }) {
                success
                issueRelation { id type }
              }
            }
            """
        case .projectSpec: """
            query ProjectSpec($id: String!) { project(id: $id) { content updatedAt } }
            """
        case .documentSpec: """
            query DocumentSpec($id: String!) { document(id: $id) { content updatedAt } }
            """
        case .changeProjectSpec: """
            mutation ChangeProjectSpec($id: String!, $content: String!) {
              projectUpdate(id: $id, input: { content: $content }) { success project { id updatedAt } }
            }
            """
        case .changeDocumentSpec: """
            mutation ChangeDocument($id: String!, $content: String!) {
              documentUpdate(id: $id, input: { content: $content }) { success document { id updatedAt } }
            }
            """
        case .postProjectUpdate: """
            mutation PostProjectUpdate($projectId: String!, $body: String!) {
              projectUpdateCreate(input: { projectId: $projectId, body: $body }) { success projectUpdate { id url } }
            }
            """
        case .planningIssues: """
            query PlanningIssues($cursor: String) {
              issues(filter: { state: { type: { nin: ["completed", "canceled", "duplicate"] } } }, first: 25, after: $cursor) {
            \(Self.planningIssueFields)
              }
            }
            """
        case .planningIssuesInTeams: """
            query PlanningIssues($teamIds: [ID!], $cursor: String) {
              issues(
                filter: { state: { type: { nin: ["completed", "canceled", "duplicate"] } }, team: { id: { in: $teamIds } } }
                first: 25
                after: $cursor
              ) {
            \(Self.planningIssueFields)
              }
            }
            """
        case .planningProjects: """
            query PlanningProjects($ids: [ID!]) {
              projects(filter: { id: { in: $ids } }, first: \(Self.planningProjectsPageSize)) {
                nodes {
                  id
                  name
                  content
                  updatedAt
                  projectMilestones(first: 25) { nodes { name } }
                }
              }
            }
            """
        case .completedIssuesSince: """
            query CompletedIssues($after: DateComparator, $cursor: String) {
              issues(filter: { completedAt: $after }, orderBy: updatedAt, first: 50, after: $cursor) {
                nodes { identifier completedAt }
                pageInfo { hasNextPage endCursor }
              }
            }
            """
        case .completedIssuesSinceInTeams: """
            query CompletedIssues($after: DateComparator, $teamIds: [ID!], $cursor: String) {
              issues(
                filter: { completedAt: $after, team: { id: { in: $teamIds } } }
                orderBy: updatedAt
                first: 50
                after: $cursor
              ) {
                nodes { identifier completedAt }
                pageInfo { hasNextPage endCursor }
              }
            }
            """
        case .teams: """
            query Teams {
              teams(first: 100) { nodes { id key name } }
            }
            """
        case .firstTeam: """
            query FirstTeam { teams(first: 1) { nodes { id } } }
            """
        case .viewer: """
            query Viewer { viewer { id } }
            """
        case .teamStates: """
            query TeamStates($id: String!) {
              team(id: $id) { triageEnabled states { nodes { id type position } } }
            }
            """
        case .enableTriage: """
            mutation EnableTriage($id: String!) {
              teamUpdate(id: $id, input: { triageEnabled: true }) { success team { id triageEnabled } }
            }
            """
        case .createComment: """
            mutation CreateComment($issueId: String!, $body: String!) {
              commentCreate(input: { issueId: $issueId, body: $body }) { success comment { id url } }
            }
            """
        case .updateComment: """
            mutation UpdateComment($id: String!, $body: String!) {
              commentUpdate(id: $id, input: { body: $body }) { success comment { id } }
            }
            """
        case .addLabel: """
            mutation AddLabel($id: String!, $labelId: String!) {
              issueAddLabel(id: $id, labelId: $labelId) { success issue { id identifier } }
            }
            """
        case .removeLabel: """
            mutation RemoveLabel($id: String!, $labelId: String!) {
              issueRemoveLabel(id: $id, labelId: $labelId) { success issue { id identifier } }
            }
            """
        case .proposalIssues: """
            query ProposalIssues($ids: [ID!], $cursor: String) {
              issues(filter: { id: { in: $ids } }, first: \(Self.proposalIssuesPageSize), after: $cursor) {
                nodes {
                  id
                  identifier
                  state { type }
                  labels(first: 50) { nodes { name } }
                  comments(first: 100) { nodes { id reactions { emoji user { id } } } }
                }
                pageInfo { hasNextPage endCursor }
              }
            }
            """
        }
    }

    /// How many issues a page of `proposalIssues` holds, and so how many IDs
    /// a request asks for. Each brings up to 100 comments with their
    /// reactions, which Linear counts toward the query's complexity.
    static let proposalIssuesPageSize = 25

    /// How many projects `planningProjects` answers with, and so how many IDs
    /// a request asks for: it reads no further pages.
    static let planningProjectsPageSize = 50

    private static let planningIssueFields = """
        nodes {
          id
          identifier
          title
          description
          priority
          updatedAt
          state { name type }
          team { id key }
          project { id name }
          projectMilestone { name }
          labels(first: 20) { nodes { name } }
          relations(first: 20) { nodes { type relatedIssue { identifier } } }
          inverseRelations(first: 20) { nodes { type issue { identifier } } }
        }
        pageInfo { hasNextPage endCursor }
    """

    /// What it takes to decide whether, and in what order, an agent starts
    /// on an issue. Pages are smaller than elsewhere, as the nested labels and
    /// relations count toward Linear's limit on a query's complexity.
    private static let candidateFields = """
        nodes {
          id
          identifier
          title
          branchName
          createdAt
          team { id key }
          state { name type }
          priority
          sortOrder
          project { sortOrder }
          projectMilestone { sortOrder }
          labels(first: 25) { nodes { name } }
          inverseRelations(first: 50) { nodes { type issue { id identifier state { type } } } }
        }
        pageInfo { hasNextPage endCursor }
    """

    private static let startedIssueFields = """
        nodes {
          id
          identifier
          title
          branchName
          state { name type }
          startedAt
        }
        pageInfo { hasNextPage endCursor }
    """
}

// MARK: - Answers

extension LinearQuery {
    /// The answer to any `issues` query: a page of nodes.
    struct IssuesData<Node: Decodable>: Decodable {
        let issues: Page

        struct Page: Decodable {
            let nodes: [Node]
            let pageInfo: PageInfo
        }

        struct PageInfo: Decodable {
            let hasNextPage: Bool
            let endCursor: String?
        }
    }

    struct IssueStateData: Decodable {
        let issue: Issue

        struct Issue: Decodable {
            let state: WorkflowState
            let team: Team
        }

        struct WorkflowState: Decodable {
            let type: String
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

    struct AttachmentsData: Decodable {
        let issue: Issue

        struct Issue: Decodable {
            let attachments: Attachments
        }

        struct Attachments: Decodable {
            let nodes: [Node]
        }

        struct Node: Decodable {
            let url: String
        }
    }

    struct EditableIssueData: Decodable {
        let issue: Issue

        struct Issue: Decodable {
            let id: LinearIssue.ID
            let identifier: String
            let description: String?
            let updatedAt: Date
            let state: State
            let team: Team
            let labels: Labels
        }

        struct State: Decodable {
            let type: LinearStateType
        }

        struct Team: Decodable {
            let id: LinearTeam.ID
        }

        struct Labels: Decodable {
            let nodes: [Label]
        }

        struct Label: Decodable {
            let name: String
        }
    }

    struct SimilarIssuesData: Decodable {
        let searchIssues: Results

        struct Results: Decodable {
            let nodes: [Node]
        }

        struct Node: Decodable {
            let id: LinearIssue.ID
            let identifier: String
            let title: String
            let state: State
        }

        struct State: Decodable {
            let type: LinearStateType
        }
    }

    struct LabelsData: Decodable {
        let issueLabels: Labels

        struct Labels: Decodable {
            let nodes: [Label]
        }

        struct Label: Decodable {
            let id: LinearLabel.ID
            let team: Team?
        }

        struct Team: Decodable {
            let id: LinearTeam.ID
        }
    }

    struct SpecNode: Decodable {
        let content: String?
        let updatedAt: Date
    }

    struct ProjectSpecData: Decodable {
        let project: SpecNode
    }

    struct DocumentSpecData: Decodable {
        let document: SpecNode
    }

    /// An open issue as the planning query answers with it.
    struct PlanningIssueNode: Decodable {
        let id: LinearIssue.ID
        let identifier: LinearIssue.Identifier
        let title: String
        let description: String?
        let priority: LinearIssue.Priority?
        let updatedAt: Date
        let state: State
        let team: Team
        let project: Project?
        let projectMilestone: Milestone?
        let labels: Nodes<Label>
        let relations: Nodes<Relation>
        let inverseRelations: Nodes<InverseRelation>

        struct State: Decodable {
            let name: String
            let type: LinearStateType
        }

        struct Team: Decodable {
            let id: LinearTeam.ID
            let key: LinearTeam.Key
        }

        struct Project: Decodable {
            let id: LinearProject.ID
            let name: LinearProject.Name
        }

        struct Milestone: Decodable {
            let name: LinearMilestone.Name
        }

        struct Label: Decodable {
            let name: LinearLabel.Name
        }

        struct Relation: Decodable {
            let type: LinearRelationType
            let relatedIssue: Related
        }

        struct InverseRelation: Decodable {
            let type: LinearRelationType
            let issue: Related
        }

        struct Related: Decodable {
            let identifier: LinearIssue.Identifier
        }

        var planningIssue: PlanningIssue {
            PlanningIssue(
                id: id, identifier: identifier, title: title, description: description ?? "",
                stateName: state.name, stateType: state.type, priority: priority, teamId: team.id, teamKey: team.key,
                projectId: project?.id, projectName: project?.name, milestone: projectMilestone?.name,
                labels: labels.nodes.map(\.name),
                relations: relations.nodes.map { PlanningRelation(type: $0.type, identifier: $0.relatedIssue.identifier, direction: .outgoing) }
                    + inverseRelations.nodes.map { PlanningRelation(type: $0.type, identifier: $0.issue.identifier, direction: .incoming) },
                updatedAt: updatedAt
            )
        }
    }

    struct Nodes<Node: Decodable>: Decodable {
        let nodes: [Node]
    }

    struct PlanningProjectsData: Decodable {
        let projects: Nodes<Project>

        struct Project: Decodable {
            let id: LinearProject.ID
            let name: LinearProject.Name
            let content: String?
            let updatedAt: Date
            let projectMilestones: Nodes<Milestone>
        }

        struct Milestone: Decodable {
            let name: LinearMilestone.Name
        }
    }

    struct PlanningTeamsData: Decodable {
        let teams: Nodes<Team>

        struct Team: Decodable {
            let id: LinearTeam.ID
            let key: LinearTeam.Key
            let name: String
        }
    }

    /// An issue as the completed-issues query answers with it.
    struct CompletedIssueNode: Decodable {
        let identifier: LinearIssue.Identifier
        let completedAt: Date
    }

    struct TeamsData: Decodable {
        let teams: Teams

        struct Teams: Decodable {
            let nodes: [Team]
        }

        struct Team: Decodable {
            let id: LinearTeam.ID
        }
    }

    struct ViewerData: Decodable {
        let viewer: Viewer

        struct Viewer: Decodable {
            let id: LinearUser.ID
        }
    }

    struct TeamStatesData: Decodable {
        let team: Team

        struct Team: Decodable {
            let triageEnabled: Bool
            let states: Nodes<State>
        }

        struct State: Decodable {
            let id: LinearState.ID
            let type: LinearStateType
            let position: Double
        }
    }

    /// An issue a proposal waits on, as the proposal-issues query answers
    /// with it.
    struct ProposalIssueNode: Decodable {
        let id: LinearIssue.ID
        let identifier: String
        let state: State
        let labels: Nodes<Label>
        let comments: Nodes<Comment>

        struct State: Decodable {
            let type: LinearStateType
        }

        struct Label: Decodable {
            let name: String
        }

        struct Comment: Decodable {
            let id: LinearComment.ID
            let reactions: [Reaction]
        }

        struct Reaction: Decodable {
            let emoji: String
            let user: User?
        }

        struct User: Decodable {
            let id: LinearUser.ID
        }

        var snapshot: ProposalIssueSnapshot {
            ProposalIssueSnapshot(
                id: id, identifier: identifier, stateType: state.type, labels: labels.nodes.map(\.name),
                comments: comments.nodes.map {
                    .init(id: $0.id, reactions: $0.reactions.map { .init(emoji: $0.emoji, userId: $0.user?.id) })
                })
        }
    }

    /// The part of a mutation's answer that says whether it worked.
    struct Success: Decodable {
        let success: Bool
    }
}

/// The names of the variables the queries take, and of the fields of the
/// inputs and filters given in them.
enum LinearVariable: String, Sendable {
    case after, body, content, cursor, description, gt, id, ids, input, issueId, keys, labelId, labelIds, name, numbers
    case projectId, relatedIssueId, stateId, states, teamId, teamIds, term, title, type, url
}

/// The names of the fields superlinear reads from Linear's answers: what
/// each mutation answers in, and the fields of the objects it returns.
enum LinearField: String, Sendable {
    case attachmentLinkURL, commentCreate, commentUpdate, documentUpdate, issueAddLabel, issueCreate, issueLabelCreate
    case issueRelationCreate, issueRemoveLabel, issueUpdate, projectUpdate, projectUpdateCreate, teamUpdate
    case comment, id, identifier, issue, issueLabel, url
}

extension JSONValue {
    subscript(field: LinearField) -> JSONValue? { self[field.rawValue] }
}
