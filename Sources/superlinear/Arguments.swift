/// What the command line asks for. Anything unrecognised is an error rather
/// than ignored: an unknown word used to fall through to running the daemon,
/// so `superlinear status`, a command this version lacks, started a second
/// daemon in the foreground.
enum Command: Equatable {
    case run(configPath: String?)
    case install(force: Bool)
    case uninstall
    case status(configPath: String?)
    case proposals(configPath: String?, workspace: String?)
    case standup(configPath: String?, workspace: String?, printOnly: Bool)
    case resume
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
            while let argument = rest.first {
                rest = rest.dropFirst()
                guard argument == "--config" else { return .invalid("unknown option for status: \(argument)") }
                guard let path = rest.first else { return .invalid("--config needs a path") }
                configPath = path
                rest = rest.dropFirst()
            }
            return .status(configPath: configPath)
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
        case "standup":
            rest = rest.dropFirst()
            var configPath: String?
            var workspace: String?
            var printOnly = false
            while let argument = rest.first {
                rest = rest.dropFirst()
                if argument == "--print" {
                    printOnly = true
                    continue
                }
                guard ["--config", "--workspace"].contains(argument) else {
                    return .invalid("unknown option for standup: \(argument)")
                }
                guard let value = rest.first else {
                    return .invalid(argument == "--config" ? "--config needs a path" : "--workspace needs a name")
                }
                if argument == "--config" { configPath = value } else { workspace = value }
                rest = rest.dropFirst()
            }
            return .standup(configPath: configPath, workspace: workspace, printOnly: printOnly)
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
