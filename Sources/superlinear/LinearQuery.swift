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
    case setDueDate

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
        case .setDueDate: """
            mutation SetDueDate($id: String!, $dueDate: TimelessDate) {
              issueUpdate(id: $id, input: { dueDate: $dueDate }) { success issue { id identifier dueDate } }
            }
            """
        }
    }

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

    /// The part of a mutation's answer that says whether it worked.
    struct Success: Decodable {
        let success: Bool
    }
}
