import Darwin
import Foundation

/// What the running daemon is, written when it starts, so `superlinear status`
/// can say which build is polling, and whether it is still running.
struct DaemonInfo: Codable, Sendable, Equatable {
    var pid: Int32
    var version: String
    /// The path launchd started it through, such as Homebrew's link.
    var executablePath: String
    var startedAt: Date
    /// The binary's identity when it started, as the binary watcher sees it.
    var binaryIdentity: String?

    static func current(now: Date = Date()) -> DaemonInfo {
        let invoked = CommandLine.arguments.first.flatMap { $0.hasPrefix("/") ? $0 : nil }
        let path = invoked ?? Bundle.main.executablePath ?? CommandLine.arguments[0]
        return DaemonInfo(
            pid: getpid(), version: Superlinear.fullVersion, executablePath: path, startedAt: now,
            binaryIdentity: BinaryWatcher.identity(of: path)
        )
    }

    static func fileURL(home: String = Paths.home) -> URL {
        URL(fileURLWithPath: "\(home)/.local/share/superlinear/daemon.json")
    }

    func write(to url: URL = fileURL()) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func read(from url: URL = fileURL()) -> DaemonInfo? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DaemonInfo.self, from: data)
    }

    /// Whether the process is alive and is this daemon, rather than another
    /// that reused its pid: one started at a different time.
    var isRunning: Bool {
        guard let started = AgentRunner.startTime(of: pid) else { return false }
        return abs(started.timeIntervalSince(startedAt)) < 5
    }

    /// The line `superlinear status` prints about it.
    func rendered(running: Bool, binaryReplaced: Bool, now: Date = Date()) -> String {
        let since = "started \(StatusTime.rendered(startedAt, now: now))"
        guard running else {
            return "Daemon: not running; it last ran \(version) from \(executablePath), \(since)"
        }
        var line = "Daemon: pid \(pid), \(version) from \(executablePath), \(since)"
        if binaryReplaced {
            line += "\n  warning: \(executablePath) has changed since the daemon started; it restarts onto the new build within a minute"
        }
        return line
    }
}

/// Times in the status report: the clock time, and how long ago or how soon.
enum StatusTime {
    static func rendered(_ date: Date, now: Date = Date()) -> String {
        let clock = date.formatted(date: Calendar.current.isDate(date, inSameDayAs: now) ? .omitted : .abbreviated, time: .standard)
        let seconds = Int(date.timeIntervalSince(now).rounded())
        return "\(clock) (\(relative(seconds)))"
    }

    static func relative(_ seconds: Int) -> String {
        let magnitude = abs(seconds)
        let amount: String
        switch magnitude {
        case ..<60: amount = "\(magnitude)s"
        case ..<3600: amount = "\(magnitude / 60)m \(magnitude % 60)s"
        case ..<86400: amount = "\(magnitude / 3600)h \(magnitude % 3600 / 60)m"
        default: amount = "\(magnitude / 86400)d \(magnitude % 86400 / 3600)h"
        }
        if magnitude == 0 { return "now" }
        return seconds < 0 ? "\(amount) ago" : "in \(amount)"
    }
}
