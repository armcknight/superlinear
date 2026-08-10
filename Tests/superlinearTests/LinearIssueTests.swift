import Foundation
import Testing
@testable import superlinear

// These decode straight off the Linear GraphQL response. branchName in
// particular is what the worktree and the eventual PR are named after.
@Suite("Linear issue decoding")
struct LinearIssueTests {
    private func decode(_ json: String) throws -> LinearIssue {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LinearIssue.self, from: Data(json.utf8))
    }

    @Test("A full node decodes, nested team included")
    func decodesFullNode() throws {
        let issue = try decode("""
        {
          "id": "uuid-1", "identifier": "SL-12", "title": "Fix the thing",
          "branchName": "armcknight/sl-12-fix-the-thing",
          "createdAt": "2026-05-01T12:00:00Z",
          "team": {"id": "team-uuid", "key": "SL"}
        }
        """)

        #expect(issue.identifier == "SL-12")
        #expect(issue.branchName == "armcknight/sl-12-fix-the-thing")
        #expect(issue.team.key == "SL")
        #expect(issue.createdAt == Date(timeIntervalSince1970: 1_777_636_800))
    }

    @Test("A missing key is an error rather than a silent empty string")
    func missingKeyThrows() {
        #expect(throws: DecodingError.self) {
            _ = try decode("""
            {"id": "uuid-1", "identifier": "SL-12", "title": "t",
             "createdAt": "2026-05-01T12:00:00Z", "team": {"id": "x", "key": "SL"}}
            """)
        }
    }

    @Test("A non-ISO8601 date is an error")
    func badDateThrows() {
        #expect(throws: DecodingError.self) {
            _ = try decode("""
            {"id": "uuid-1", "identifier": "SL-12", "title": "t",
             "branchName": "b", "createdAt": "last tuesday",
             "team": {"id": "x", "key": "SL"}}
            """)
        }
    }

    // The daemon filters on ids it has already seen, so an id must compare by
    // value. This is the property State's dedupe relies on.
    @Test("Issue ids are distinct from identifiers")
    func idAndIdentifierAreDifferentFields() throws {
        let issue = try decode("""
        {"id": "uuid-1", "identifier": "SL-12", "title": "t", "branchName": "b",
         "createdAt": "2026-05-01T12:00:00Z", "team": {"id": "x", "key": "SL"}}
        """)

        #expect(issue.id == "uuid-1")
        #expect(issue.identifier == "SL-12")
    }
}
