import Foundation
import Testing
@testable import superlinear

@Suite("Linear variables")
struct LinearVariableTests {
    @Test("Variables, and the inputs and filters nested in them, are sent by name")
    func encodesNestedNames() throws {
        let variables: [LinearVariable: Any] = [
            .after: [LinearVariable.gt: "2027-01-15T08:00:00Z"],
            .input: [LinearVariable.teamId: "t1", .labelIds: ["l1", "l2"]],
            .ids: ["a", "b"],
        ]
        let data = try JSONSerialization.data(withJSONObject: LinearClient.encoded(variables), options: .sortedKeys)
        #expect(String(decoding: data, as: UTF8.self)
            == #"{"after":{"gt":"2027-01-15T08:00:00Z"},"ids":["a","b"],"input":{"labelIds":["l1","l2"],"teamId":"t1"}}"#)
    }
}
