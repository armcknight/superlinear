import Foundation

struct WorkspaceConfig: Codable, Sendable {
    let name: String
    let apiKey: String
    let repoPath: String
    let teamIds: [String]
    let pollIntervalSeconds: Int

    enum CodingKeys: String, CodingKey {
        case name, apiKey, repoPath, teamIds, pollIntervalSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        repoPath = try container.decode(String.self, forKey: .repoPath)
        teamIds = try container.decodeIfPresent([String].self, forKey: .teamIds) ?? []
        pollIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 60
    }
}

struct Config: Codable, Sendable {
    let workspaces: [WorkspaceConfig]

    static func load(from path: String? = nil) throws -> Config {
        let configPath = path ?? (FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/superlinear/config.json").path)
        let url = URL(fileURLWithPath: configPath)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Config.self, from: data)
    }
}
