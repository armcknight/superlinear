import Foundation
import Tagged

/// The Claude plan's usage limit, as a `claude` session reports it when it
/// stops. All workspaces share one Claude login, so when one session hits the
/// limit, every session would: the daemon pauses them all until the reset.
///
/// Claude has said it in several ways over time. Each known form is matched
/// here, and nowhere else:
///
/// - `Claude AI usage limit reached|1760000000`, with the reset as a Unix time
/// - `You've hit your session limit · resets 2:30am (America/Anchorage)`, and
///   `You've hit your limit`, `You've hit your weekly limit` and the like
/// - `5-hour limit reached ∙ resets 3pm`, `Weekly limit reached ∙ resets Oct 20, 3pm`
///   and `Opus weekly limit reached ∙ resets Mon 9am`, and the same for Fable
/// - `Claude usage limit reached. Your limit will reset at 3pm (America/Los_Angeles).`
///
/// Any of them may come without a reset time.
enum ClaudeUsageLimit {
    /// When the limit resets, as Claude said it: its own kind of date, so it
    /// is not mixed up with the others a pause keeps.
    typealias ResetTime = Tagged<ClaudeUsageLimit, Date>

    /// A usage limit message, with the reset time when it gave one.
    struct Hit: Equatable, Sendable {
        var resetAt: ResetTime?
    }

    /// The lines at the end of a session's output that are searched. The
    /// message is the session's last output; an agent that only talks about
    /// usage limits, as one working on this code does, says so earlier.
    static let linesSearched = 3

    /// The usage limit message at the end of `output`, if it is there.
    static func hit(in output: String, now: Date, timeZone: TimeZone) -> Hit? {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for line in lines.suffix(linesSearched).reversed() {
            if let hit = hit(line: line, now: now, timeZone: timeZone) { return hit }
        }
        return nil
    }

    /// The message, when `line` is one. Only a line that starts with it
    /// counts, after any JSON or log prefix around a quoted message.
    static func hit(line: String, now: Date, timeZone: TimeZone) -> Hit? {
        let text = unquoted(line)
        if let match = text.firstMatch(of: /^Claude AI usage limit reached(?:\|(\d{9,11}))?/) {
            let reset = match.output.1.flatMap { TimeInterval($0) }.map(Date.init(timeIntervalSince1970:))
            return Hit(resetAt: reset.map(ResetTime.init(rawValue:)))
        }
        let forms = [
            /^You(?:'|’)ve hit your (?:(?:usage|session|weekly|daily|opus|sonnet|fable|\d+-hour) )*limit\b/.ignoresCase(),
            /^(?:Claude (?:AI )?usage |(?:(?:session|weekly|daily|opus|sonnet|fable|\d+-hour) )+)limit reached\b/.ignoresCase(),
        ]
        guard forms.contains(where: { text.firstMatch(of: $0) != nil }) else { return nil }
        return Hit(resetAt: resetTime(in: text, now: now, timeZone: timeZone).map(ResetTime.init(rawValue:)))
    }

    /// The text of a JSON result line such as `{"type":"result",…,"result":"Claude AI usage limit reached|…"}`,
    /// or the line itself.
    private static func unquoted(_ line: String) -> String {
        guard line.hasPrefix("{"), let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? String
        else { return line }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The reset time after "resets" or "reset at": a time of day, perhaps
    /// after a weekday or a month and day, perhaps followed by a time zone in
    /// brackets. A time with no day is the next one to come.
    static func resetTime(in text: String, now: Date, timeZone: TimeZone) -> Date? {
        let pattern = /(?i)reset(?:s| at)\s+(?:(mon|tue|wed|thu|fri|sat|sun)[a-z]*,?\s+)?(?:(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2}),?\s+(?:at\s+)?)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?(?:\s*\(([^)]+)\))?/
        guard let match = text.firstMatch(of: pattern), var hour = Int(match.output.4) else { return nil }
        let minute = match.output.5.flatMap { Int($0) } ?? 0
        switch match.output.6?.lowercased() {
        case "am"?: hour = hour == 12 ? 0 : hour
        case "pm"?: hour = hour == 12 ? 12 : hour + 12
        default: break
        }
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = match.output.7.flatMap { TimeZone(identifier: String($0)) } ?? timeZone
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let weekdays = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

        var components = DateComponents(hour: hour, minute: minute, second: 0)
        if let month = match.output.2.flatMap({ months.firstIndex(of: $0.lowercased()) }),
           let day = match.output.3.flatMap({ Int($0) }) {
            components.month = month + 1
            components.day = day
        } else if let weekday = match.output.1.flatMap({ weekdays.firstIndex(of: $0.lowercased()) }) {
            components.weekday = weekday + 1
        }
        // The first such time after a minute ago, so a reset due now is now.
        return calendar.nextDate(
            after: now.addingTimeInterval(-60), matching: components, matchingPolicy: .nextTime)
    }
}

/// A pause of every Claude session while the usage limit is used up. Kept in
/// the state file, so `superlinear status` can show it and a restarted daemon
/// keeps it.
struct ClaudePause: Codable, Sendable, Equatable {
    /// When the limit was first hit.
    var since: Date
    /// When Claude said the limit resets, or `fallbackDelay` after it was hit
    /// when it did not say.
    var until: ClaudeUsageLimit.ResetTime
    /// When the next small session checks whether the limit was lifted early,
    /// as when the owner bought more usage.
    var nextCheckAt: Date

    /// How long to pause when Claude gives no reset time.
    static let fallbackDelay: TimeInterval = 60 * 60
    /// How often a paused daemon checks whether the limit was lifted.
    static let checkInterval: TimeInterval = 15 * 60

    init(since: Date, until: ClaudeUsageLimit.ResetTime, nextCheckAt: Date) {
        self.since = since
        self.until = until
        self.nextCheckAt = nextCheckAt
    }

    /// The pause for a limit hit at `now`.
    init(hit: ClaudeUsageLimit.Hit, now: Date) {
        let until = hit.resetAt.flatMap { $0.rawValue > now ? $0 : nil }
            ?? ClaudeUsageLimit.ResetTime(rawValue: now.addingTimeInterval(Self.fallbackDelay))
        self.init(since: now, until: until, nextCheckAt: now.addingTimeInterval(Self.checkInterval))
    }

    /// The pause after another session, or a check, hit the limit at `now`:
    /// it lasts until the new reset time, or as long as it did when the new
    /// message gives none.
    func extended(by hit: ClaudeUsageLimit.Hit, now: Date) -> ClaudePause {
        var pause = self
        if let reset = hit.resetAt, reset.rawValue > now { pause.until = reset }
        pause.nextCheckAt = now.addingTimeInterval(Self.checkInterval)
        return pause
    }

    func isOver(now: Date) -> Bool { now >= until.rawValue }

    /// Whether a check is due: the pause is not over, and the last check was
    /// at least `checkInterval` ago.
    func checkDue(now: Date) -> Bool { !isOver(now: now) && now >= nextCheckAt }

    /// What a check found.
    enum Check: Equatable, Sendable {
        /// The session answered: the limit was lifted.
        case lifted
        /// The session hit the limit again.
        case limited(ClaudeUsageLimit.Hit)
        /// The session failed for another reason, such as no network.
        case failed(String)
    }

    /// The pause after a check at `now`, or nil when the limit was lifted.
    func after(_ check: Check, now: Date) -> ClaudePause? {
        switch check {
        case .lifted:
            return nil
        case .limited(let hit):
            return extended(by: hit, now: now)
        case .failed:
            var pause = self
            pause.nextCheckAt = now.addingTimeInterval(Self.checkInterval)
            return pause
        }
    }

    /// The line `superlinear status` prints about it.
    func rendered(waiting: Int, now: Date) -> String {
        let time = { (date: Date) in StatusTime.clock(date, now: now) }
        let next = checkDue(now: now) ? "checking now" : "next check \(time(nextCheckAt))"
        return "Claude usage limit: paused until \(time(until.rawValue)) (\(next)), "
            + "\(waiting) session\(waiting == 1 ? "" : "s") waiting"
    }

    /// The smallest session there is: one word in, no tools. It costs a few
    /// tokens, and tells whether the limit was lifted.
    static let checkArguments = ["claude", "-p", "--tools", "", "--output-format", "text", "Reply with one word: ok"]

    /// How long the check session may take before it is stopped.
    static let checkTimeout: TimeInterval = 120

    /// Runs the check session and reads its result.
    static func check(environment: [String: String]) async -> Check {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = checkArguments
            process.environment = environment
            process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return .failed("\(error)")
            }
            // A session that hangs must not hold up the pause for good.
            DispatchQueue.global().asyncAfter(deadline: .now() + checkTimeout) {
                if process.isRunning { process.terminate() }
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Self.reading(String(decoding: data, as: UTF8.self), status: process.terminationStatus, now: Date())
        }.value
    }

    /// What a check session's output and exit status say.
    static func reading(_ output: String, status: Int32, now: Date) -> Check {
        if let hit = ClaudeUsageLimit.hit(in: output, now: now, timeZone: .current) { return .limited(hit) }
        guard status == 0 else {
            return .failed("`claude` exited \(status): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return .lifted
    }
}
