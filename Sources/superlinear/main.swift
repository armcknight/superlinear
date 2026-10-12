import Foundation

// launchd sends stdout to the daemon log, a file, which makes it block-buffered:
// lines would appear only once the buffer filled. Flush each line instead.
setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
Usage: superlinear [--config <path>]
       superlinear install [--force]
       superlinear uninstall

Watches Linear for new issues and starts an autonomous Claude Code agent
for each one. With no subcommand, runs the daemon in the foreground.

Subcommands:
  install     Write the launchd agent for this binary and load it, so the
              daemon starts at login. Reinstalling reloads it. A Homebrew
              binary leaves an agent that runs a local build in place;
              --force replaces it anyway.
  uninstall   Unload the launchd agent and remove it.

Options:
  --config <path>   Config file. Default: ~/.config/superlinear/config.json
  --version         Print the version and exit.
  --help, -h        Print this message and exit.
"""

// Subcommands run to completion and exit; they never reach the run loop.
var configPath: String?
switch Command.parse(Array(CommandLine.arguments.dropFirst())) {
case .install(let force):
    let agent = LaunchAgent.current()
    if !force, let devBinary = agent.devBinaryToKeep() {
        print("[superlinear] Kept the agent for the local build at \(devBinary)")
        print("  A local build takes precedence over Homebrew. Use --force to replace it,")
        print("  or `make unload` in the superlinear repo to remove it first.")
        exit(0)
    }
    do {
        try agent.install()
        print("[superlinear] Loaded \(LaunchAgent.label)")
        print("  Agent:  \(agent.plistPath)")
        print("  Binary: \(agent.executablePath)")
        print("  Log:    \(agent.logPath)")
        print("Configure it with: superlinear --help")
        exit(0)
    } catch {
        print("[superlinear] Install failed: \(error.localizedDescription)")
        exit(1)
    }

case .uninstall:
    do {
        try LaunchAgent.current().uninstall()
        print("[superlinear] Unloaded and removed \(LaunchAgent.label)")
        exit(0)
    } catch {
        print("[superlinear] Uninstall failed: \(error.localizedDescription)")
        exit(1)
    }

case .version:
    print(Superlinear.fullVersion)
    exit(0)

case .help:
    print(usage)
    exit(0)

case .invalid(let message):
    FileHandle.standardError.write(Data("superlinear: \(message)\n\n\(usage)\n".utf8))
    exit(64) // EX_USAGE

case .run(let path):
    configPath = path
}

let stateDirectory = "\(Paths.home)/.local/share/superlinear"
try? FileManager.default.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true)
if case .held(let holder) = DaemonLock.acquire(path: "\(stateDirectory)/daemon.lock") {
    let who = holder.map { "pid \($0)" } ?? "another process"
    print("[superlinear] Another daemon is already running (\(who)); exiting")
    exit(1)
}

// Ignore default signal handlers so DispatchSource can intercept them
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)

var daemonTask: Task<Void, Error>?
var binaryWatcher: BinaryWatcher?

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
    binaryWatcher = BinaryWatcher.watchedPath().map(BinaryWatcher.start)
} catch {
    print("[superlinear] Failed to load config: \(error)")
    exit(1)
}

RunLoop.main.run()
