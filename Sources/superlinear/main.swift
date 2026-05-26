import Foundation

// Ignore default signal handlers so DispatchSource can intercept them
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)

var daemonTask: Task<Void, Error>?

let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler {
    print("[superlinear] Received SIGTERM, shutting down...")
    daemonTask?.cancel()
    exit(0)
}
sigterm.resume()

let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    print("[superlinear] Received SIGINT, shutting down...")
    daemonTask?.cancel()
    exit(0)
}
sigint.resume()

// Parse --config flag
var configPath: String? = nil
var args = CommandLine.arguments.dropFirst()
while let arg = args.first {
    if arg == "--config", let next = args.dropFirst().first {
        configPath = next
        args = args.dropFirst(2)
    } else if arg == "--help" || arg == "-h" {
        print("Usage: superlinear [--config <path>]")
        print("  Monitors Linear.app for new issues and spawns Claude Code agents.")
        print("  Config: ~/.config/superlinear/config.json")
        exit(0)
    } else {
        args = args.dropFirst()
    }
}

do {
    let config = try Config.load(from: configPath)

    if config.workspaces.isEmpty {
        print("[superlinear] No workspaces configured. Edit ~/.config/superlinear/config.json")
        exit(1)
    }

    let daemon = Daemon(config: config)
    daemonTask = Task {
        try await daemon.run()
    }
} catch {
    print("[superlinear] Failed to load config: \(error)")
    exit(1)
}

RunLoop.main.run()
