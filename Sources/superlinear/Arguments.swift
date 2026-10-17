import Foundation

/// What the command line asks for. Anything unrecognised is an error rather
/// than ignored: an unknown word used to fall through to running the daemon,
/// so `superlinear status`, a command this version lacks, started a second
/// daemon in the foreground.
enum Command: Equatable {
    case run(configPath: String?)
    case install(force: Bool)
    case uninstall
    /// `since` is how far back "Done autonomously" looks; nil for the default.
    case status(configPath: String?, since: TimeInterval?)
    case proposals(configPath: String?, workspace: String?)
    case resume
    case plan(configPath: String?, workspace: String?)
    case version
    case help
    case invalid(String)

    static func parse(_ arguments: [String]) -> Command {
        var rest = arguments[...]
        switch rest.first {
        case "install":
            rest = rest.dropFirst()
            var force = false
            for argument in rest {
                guard argument == "--force" else { return .invalid("unknown option for install: \(argument)") }
                force = true
            }
            return .install(force: force)
        case "resume":
            if let extra = rest.dropFirst().first { return .invalid("unknown option for resume: \(extra)") }
            return .resume
        case "uninstall":
            if let extra = rest.dropFirst().first { return .invalid("unknown option for uninstall: \(extra)") }
            return .uninstall
        case "status":
            rest = rest.dropFirst()
            var configPath: String?
            var since: TimeInterval?
            while let argument = rest.first {
                rest = rest.dropFirst()
                switch argument {
                case "--config":
                    guard let path = rest.first else { return .invalid("--config needs a path") }
                    configPath = path
                case "--since":
                    guard let text = rest.first, let duration = StatusReview.duration(text) else {
                        return .invalid("--since needs a duration such as 24h, 7d or 90m")
                    }
                    since = duration
                default:
                    return .invalid("unknown option for status: \(argument)")
                }
                rest = rest.dropFirst()
            }
            return .status(configPath: configPath, since: since)
        case "proposals":
            rest = rest.dropFirst()
            var configPath: String?
            var workspace: String?
            while let argument = rest.first {
                rest = rest.dropFirst()
                guard ["--config", "--workspace"].contains(argument) else {
                    return .invalid("unknown option for proposals: \(argument)")
                }
                guard let value = rest.first else {
                    return .invalid(argument == "--config" ? "--config needs a path" : "--workspace needs a name")
                }
                if argument == "--config" { configPath = value } else { workspace = value }
                rest = rest.dropFirst()
            }
            return .proposals(configPath: configPath, workspace: workspace)
        case "plan":
            rest = rest.dropFirst()
            var configPath: String?
            var workspace: String?
            while let argument = rest.first {
                rest = rest.dropFirst()
                guard ["--config", "--workspace"].contains(argument) else {
                    return .invalid("unknown option for plan: \(argument)")
                }
                guard let value = rest.first else {
                    return .invalid(argument == "--config" ? "--config needs a path" : "--workspace needs a name")
                }
                if argument == "--config" { configPath = value } else { workspace = value }
                rest = rest.dropFirst()
            }
            return .plan(configPath: configPath, workspace: workspace)
        default:
            break
        }

        var configPath: String?
        while let argument = rest.first {
            rest = rest.dropFirst()
            switch argument {
            case "--config":
                guard let path = rest.first else { return .invalid("--config needs a path") }
                configPath = path
                rest = rest.dropFirst()
            case "--version":
                return .version
            case "--help", "-h":
                return .help
            default:
                return argument.hasPrefix("-")
                    ? .invalid("unknown option: \(argument)")
                    : .invalid("unknown command: \(argument)")
            }
        }
        return .run(configPath: configPath)
    }
}
