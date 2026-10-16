import Foundation

/// One change superlinear made in Linear: when, the proposal it applied, and
/// what Linear answered.
struct AuditEntry: Codable, Sendable, Equatable {
    var time: Date
    var workspace: String
    var proposal: Proposal
    var response: JSONValue
}

/// Each workspace's changes to Linear, one JSON object a line, appended to
/// and never rewritten.
struct AuditLog: Sendable {
    let directory: URL

    init(directory: URL = AuditLog.defaultDirectory()) {
        self.directory = directory
    }

    static func defaultDirectory() -> URL {
        URL(fileURLWithPath: "\(Paths.home)/.local/share/superlinear/audit")
    }

    func fileURL(workspace: String) -> URL {
        // A name is free text in the config; keep it to one path component.
        directory.appendingPathComponent(workspace.replacingOccurrences(of: "/", with: "_") + ".jsonl")
    }

    func append(_ entry: AuditEntry) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(entry)
        line.append(UInt8(ascii: "\n"))

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(workspace: entry.workspace)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    func entries(workspace: String) throws -> [AuditEntry] {
        let url = fileURL(workspace: workspace)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map { try decoder.decode(AuditEntry.self, from: Data($0.utf8)) }
    }
}
