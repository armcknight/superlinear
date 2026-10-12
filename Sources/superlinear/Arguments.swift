/// What the command line asks for. Anything unrecognised is an error rather
/// than ignored: an unknown word used to fall through to running the daemon,
/// so `superlinear status`, a command this version lacks, started a second
/// daemon in the foreground.
enum Command: Equatable {
    case run(configPath: String?)
    case install(force: Bool)
    case uninstall
    case status(configPath: String?)
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
