import Foundation

/// Who does a step of the roadmap.
enum RoadmapActor: String, Codable, Sendable, Equatable {
    /// An agent superlinear starts.
    case agent
    /// The owner.
    case you
}

/// Why the data, rather than the roadmap session, says that the owner acts
/// on an issue.
struct OwnerReason: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        /// The issue has a human label, which keeps agents off it.
        case humanLabel
        /// The issue waits in Triage, as a proposed issue or one a person filed.
        case triage
        /// A proposal on the issue waits for the owner's answer in a comment.
        case proposal
        /// A pull request of the issue waits for the owner's review or merge.
        case review
    }

    var kind: Kind
    /// What the owner does, as a line under "Now, for you".
    var text: String
    /// The page it is done on, when there is one.
    var url: String?
}

/// An identifier of another configured workspace's team in an issue's
/// description, such as "waits for WOR-7" in a TEM issue. Linear cannot
/// relate issues in different workspaces, so the roadmap reads such a
/// mention as a dependency on that issue.
struct CrossReference: Codable, Sendable, Equatable {
    /// The issue whose description names the other.
    var issue: LinearIssue.Identifier
    var workspace: String
    /// The issue named.
    var target: LinearIssue.Identifier
    /// The workspace that watches the team of `target`; nil when none does,
    /// and the identifier is unknown, or when it is `ambiguous`.
    var targetWorkspace: String?
    /// Whether `target` is among the open issues of `targetWorkspace`.
    var targetOpen: Bool
    /// The workspaces with a team of `target`'s key, when there are several
    /// and not exactly one of them has `target` open, so it cannot be told
    /// which is meant.
    var ambiguous: [String]? = nil

    /// Finds them in `workspaces`. Mentions of a team of the issue's own
    /// workspace are left to Linear's relations.
    static func find(in workspaces: [RoadmapWorkspace]) -> [CrossReference] {
        var owners: [String: [String]] = [:]
        for workspace in workspaces {
            for key in workspace.teamKeys { owners[key, default: []].append(workspace.name) }
        }
        let open = Set(workspaces.flatMap { workspace in workspace.issues.map { "\(workspace.name):\($0.identifier.rawValue.uppercased())" } })
        var found: [CrossReference] = []
        for workspace in workspaces {
            let own = Set(workspace.teamKeys)
            for issue in workspace.issues.sorted(by: { $0.identifier.sortsBefore($1.identifier) }) {
                var named: Set<String> = []
                // An identifier as people write one in prose: upper case, as
                // `WOR-7`. A branch name's `wor-7` is not prose.
                for match in issue.description.matches(of: /\b([A-Z][A-Z0-9]*)-([0-9]+)\b/) {
                    let key = String(match.output.1)
                    let target = "\(key)-\(match.output.2)"
                    guard !own.contains(key), !notTeamKeys.contains(key), named.insert(target).inserted else { continue }
                    let candidates = owners[key] ?? []
                    let openIn = candidates.filter { open.contains("\($0):\(target)") }
                    let owner = candidates.count == 1 ? candidates.first : (openIn.count == 1 ? openIn.first : nil)
                    found.append(
                        CrossReference(
                            issue: issue.identifier, workspace: workspace.name, target: LinearIssue.Identifier(rawValue: target),
                            targetWorkspace: owner, targetOpen: owner.map(openIn.contains) ?? false,
                            ambiguous: candidates.count > 1 && owner == nil ? candidates : nil))
                }
            }
        }
        return found
    }

    /// Words written like identifiers that name no team, as in UTF-8.
    static let notTeamKeys: Set<String> = ["UTF", "SHA", "ISO", "RFC", "CVE", "MD", "X", "ES", "WCAG"]

    /// The line the roadmap prints for it; `step` is the step that holds `target`.
    func rendered(step: Int?) -> String {
        if let ambiguous {
            return "\(issue) names \(target), of a team key in \(ambiguous.joined(separator: " and ")) (ambiguous)"
        }
        guard let targetWorkspace else {
            return "\(issue) names \(target), of a team no workspace watches (unknown)"
        }
        guard targetOpen else { return "\(issue) waits for \(target) in \(targetWorkspace), which is not open" }
        return "\(issue) waits for \(target) in \(targetWorkspace)" + (step.map { ", step \($0)" } ?? "")
    }
}

/// An issue as the roadmap shows it.
struct RoadmapIssue: Codable, Sendable, Equatable {
    var identifier: LinearIssue.Identifier
    var title: String
    var workspace: String
    var state: String
    var url: String?
    /// Why the owner acts on it; empty when the data says nothing.
    var owner: [OwnerReason] = []
}

/// The ordered plan across workspaces, with what the owner must do now, as
/// `superlinear roadmap` shows it.
struct Roadmap: Codable, Sendable, Equatable {
    struct Step: Codable, Sendable, Equatable {
        var number: Int
        /// What the step is, with the identifiers of its issues.
        var work: String
        var issues: [RoadmapIssue]
        /// Who does it, in order: "agent, then you".
        var who: [RoadmapActor]
        /// Why it is in its place.
        var why: String?
    }

    /// Something the owner must do now so that agents are not waiting.
    struct Action: Codable, Sendable, Equatable {
        var text: String
        /// The step it unblocks.
        var step: Int?
        var issues: [LinearIssue.Identifier]
        var url: String?
    }

    /// A note for triage, such as duplicates and issues that belong together.
    struct Note: Codable, Sendable, Equatable {
        var text: String
        var issues: [LinearIssue.Identifier]
    }

    var builtAt: Date
    /// The workspaces it covers, in config order.
    var workspaces: [String]
    /// The head of each workspace's default branch it looked at.
    var heads: [String: GitCommit.SHA]
    var steps: [Step]
    var actions: [Action]
    var triage: [Note]
    var references: [CrossReference]
    /// What went wrong gathering it, or in the session's output.
    var warnings: [String]
    var model: PlanningModel?
    var usage: AgentUsage?

    /// The step that holds `identifier`.
    func step(of identifier: LinearIssue.Identifier, in workspace: String) -> Int? {
        steps.first { $0.issues.contains { $0.identifier == identifier && $0.workspace == workspace } }?.number
    }

    // MARK: - Building

    /// The roadmap from the session's `output` and the `context` it was
    /// given. The session orders and explains; this part makes it whole:
    /// each open issue lands in one step, the first that names it, and those
    /// it left out get steps of their own at the end; a step with an issue
    /// the owner acts on has `you` among its Who; and each such issue has an
    /// action under "Now, for you".
    static func assemble(
        _ output: RoadmapOutput, context: RoadmapContext, model: PlanningModel?, usage: AgentUsage?
    ) -> Roadmap {
        let index = RoadmapIssueIndex(context)
        var warnings = context.warnings
        var placed: Set<String> = []
        var steps: [Step] = []
        /// The session's step numbers, as they are once renumbered.
        var renumbered: [Int: Int] = [:]
        for (position, item) in output.steps.enumerated() {
            var issues: [RoadmapIssue] = []
            for named in item.issues ?? [] {
                switch index.find(named) {
                case .found(let issue):
                    guard placed.insert(RoadmapIssueIndex.key(issue)).inserted else { continue }
                    issues.append(issue)
                case .ambiguous(let workspaces):
                    warnings.append(
                        "Step \(position + 1) names \(named), which is in \(workspaces.joined(separator: " and ")); "
                            + "it should say which, as \(workspaces[0]):\(named)")
                case .missing:
                    warnings.append("Step \(position + 1) names \(named), which is not an open issue of these workspaces")
                }
            }
            let work = item.work.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !issues.isEmpty || (!work.isEmpty && (item.issues ?? []).isEmpty) else { continue }
            let number = steps.count + 1
            renumbered[position + 1] = number
            steps.append(Step(number: number, work: work, issues: issues, who: who(item.who, issues: issues), why: nonEmpty(item.why)))
        }
        for issue in index.all where !placed.contains(RoadmapIssueIndex.key(issue)) {
            steps.append(
                Step(
                    number: steps.count + 1, work: "", issues: [issue], who: who([], issues: [issue]),
                    why: "Not placed by the roadmap session"))
        }
        for position in steps.indices {
            steps[position].work = work(steps[position], index: index)
        }

        var actions: [Action] = []
        for item in output.actions ?? [] {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let issues = index.found(item.issues ?? [])
            var step = item.step.flatMap { renumbered[$0] }
            if step == nil, let first = issues.first { step = steps.first { $0.issues.contains(first) }?.number }
            actions.append(Action(text: text, step: step, issues: issues.map(\.identifier), url: nil))
        }
        let named = Set(output.actions?.flatMap { index.found($0.issues ?? []).map(RoadmapIssueIndex.key) } ?? [])
        for step in steps {
            for issue in step.issues where !named.contains(RoadmapIssueIndex.key(issue)) {
                for reason in issue.owner {
                    actions.append(
                        Action(
                            text: "\(index.display(issue)): \(reason.text)", step: step.number, issues: [issue.identifier], url: reason.url))
                }
            }
        }

        let triage: [Note] = (output.triage ?? []).compactMap { item in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Note(text: text, issues: index.found(item.issues ?? []).map(\.identifier))
        }

        return Roadmap(
            builtAt: context.builtAt, workspaces: context.workspaces.map(\.name),
            heads: context.workspaces.reduce(into: [:]) { heads, workspace in heads[workspace.name] = workspace.head },
            steps: steps, actions: actions, triage: triage, references: context.references, warnings: warnings,
            model: model, usage: usage)
    }

    /// The session's Who, with `you` first when an issue the owner acts on
    /// is in the step and the session left the owner out, and `agent` when
    /// it named no one.
    static func who(_ named: [String], issues: [RoadmapIssue]) -> [RoadmapActor] {
        var actors = named.compactMap { RoadmapActor(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) }
        if issues.contains(where: { !$0.owner.isEmpty }), !actors.contains(.you) { actors.insert(.you, at: 0) }
        return actors.isEmpty ? [.agent] : actors
    }

    /// The step's work, with each of its issues that the text does not name
    /// added with its title.
    private static func work(_ step: Step, index: RoadmapIssueIndex) -> String {
        let missing = step.issues.filter { issue in
            step.work.range(of: "\\b\(NSRegularExpression.escapedPattern(for: issue.identifier.rawValue))\\b", options: [.regularExpression, .caseInsensitive]) == nil
        }
        let added = missing.map { "\(index.display($0)) (\($0.title))" }.joined(separator: ", ")
        if step.work.isEmpty { return added }
        return added.isEmpty ? step.work : "\(step.work); \(added)"
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    // MARK: - Rendering

    /// The table, the cross-workspace waits, "Now, for you" and "Triage".
    /// With `links`, issue identifiers link to Linear, for a terminal that
    /// shows links. `moved` names the workspaces whose default branch moved
    /// since it was built.
    func rendered(now: Date, links: Bool, moved: [String] = []) -> String {
        var lines = ["Roadmap of \(workspaces.joined(separator: ", ")), built \(StatusTime.rendered(builtAt, now: now))"]
        if !moved.isEmpty {
            lines.append(
                "The default branch of \(moved.joined(separator: ", ")) moved since; `superlinear roadmap --refresh` builds a new one.")
        }
        lines.append("")
        let issues = steps.flatMap(\.issues)
        let link: (String) -> String = { links ? Self.linked($0, issues: issues) : $0 }

        if steps.isEmpty {
            lines.append("No open issues.")
        } else {
            let rows = [("Step", "Work", "Who")]
                + steps.map { (String($0.number), $0.work, $0.who.map(\.rawValue).joined(separator: ", then ")) }
            let numberWidth = rows.map(\.0.count).max() ?? 0
            let wrapped = rows.map { (number: $0.0, work: Self.wrapped($0.1, width: Self.workWidth), who: $0.2) }
            let workWidth = wrapped.flatMap(\.work).map(\.count).max() ?? 0
            for row in wrapped {
                for (index, part) in row.work.enumerated() {
                    let padded = (index == 0 ? row.number : "").padding(toLength: numberWidth, withPad: " ", startingAt: 0) + "  "
                        + part.padding(toLength: workWidth, withPad: " ", startingAt: 0) + "  " + (index == 0 ? row.who : "")
                    lines.append(link(padded.trimmingTrailingWhitespace()))
                }
            }
        }

        if !references.isEmpty {
            lines.append("\nWaits across workspaces")
            for reference in references {
                let number = reference.targetWorkspace.flatMap { self.step(of: reference.target, in: $0) }
                lines.append(link("  " + reference.rendered(step: number)))
            }
        }

        lines.append("\nNow, for you")
        if actions.isEmpty { lines.append("  Nothing.") }
        for action in actions {
            var line = "  - \(action.text)"
            if let step = action.step { line += " (unblocks step \(step))" }
            if let url = action.url, !links { line += " \(url)" }
            lines.append(link(line))
        }

        if !triage.isEmpty {
            lines.append("\nTriage")
            for note in triage { lines.append(link("  - \(note.text)")) }
        }

        if !warnings.isEmpty {
            lines.append("")
            for warning in warnings { lines.append("warning: \(warning)") }
        }
        return lines.joined(separator: "\n")
    }

    /// The widest the Work column grows before its text wraps.
    static let workWidth = 72

    /// `text` in lines of at most `width` characters, broken between words;
    /// a word longer than `width` has a line of its own.
    static func wrapped(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            if !line.isEmpty, line.count + 1 + word.count > width {
                lines.append(line)
                line = ""
            }
            line += (line.isEmpty ? "" : " ") + word
        }
        lines.append(line)
        return lines
    }

    /// `text` with each identifier of `issues` that has a URL made a
    /// terminal link (OSC 8) to it. An identifier two workspaces have links
    /// to neither.
    static func linked(_ text: String, issues: [RoadmapIssue]) -> String {
        let urls = Dictionary(issues.map { ($0.identifier.rawValue, $0.url) }, uniquingKeysWith: { _, _ in nil }).compactMapValues { $0 }
        guard !urls.isEmpty else { return text }
        return text.replacing(/\b[A-Z][A-Z0-9]*-[0-9]+\b/) { match in
            let identifier = String(match.output)
            guard let url = urls[identifier] else { return identifier }
            return "\u{1b}]8;;\(url)\u{1b}\\\(identifier)\u{1b}]8;;\u{1b}\\"
        }
    }

    /// The roadmap as `--json` prints it.
    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// The open issues of a roadmap's workspaces, found by identifier. Two
/// workspaces may have teams with the same key, so an identifier alone may
/// name two issues; `workspace:identifier` names one.
struct RoadmapIssueIndex {
    enum Match: Equatable {
        case found(RoadmapIssue)
        /// The workspaces that have an open issue with the identifier.
        case ambiguous([String])
        case missing
    }

    /// Every open issue, by workspace in config order, then by identifier.
    let all: [RoadmapIssue]
    private let byKey: [String: RoadmapIssue]
    private let byIdentifier: [String: [RoadmapIssue]]

    init(_ context: RoadmapContext) {
        var all: [RoadmapIssue] = []
        for workspace in context.workspaces {
            for issue in workspace.issues.sorted(by: { $0.identifier.sortsBefore($1.identifier) }) {
                all.append(
                    RoadmapIssue(
                        identifier: issue.identifier, title: issue.title, workspace: workspace.name, state: issue.stateName,
                        url: issue.url, owner: workspace.ownerReasons(for: issue)))
            }
        }
        self.all = all
        byKey = Dictionary(all.map { (Self.key($0), $0) }, uniquingKeysWith: { a, _ in a })
        byIdentifier = Dictionary(grouping: all) { $0.identifier.rawValue.uppercased() }
    }

    /// The key that names one issue: `workspace:IDENTIFIER`.
    static func key(_ issue: RoadmapIssue) -> String { "\(issue.workspace.lowercased()):\(issue.identifier.rawValue.uppercased())" }

    /// The identifiers that more than one workspace has.
    var shared: Set<String> { Set(byIdentifier.filter { $0.value.count > 1 }.keys) }

    func find(_ named: String) -> Match {
        let named = named.trimmingCharacters(in: .whitespaces)
        if let colon = named.firstIndex(of: ":") {
            let workspace = named[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let identifier = named[named.index(after: colon)...].trimmingCharacters(in: .whitespaces).uppercased()
            return byKey["\(workspace):\(identifier)"].map { .found($0) } ?? .missing
        }
        let matches = byIdentifier[named.uppercased()] ?? []
        switch matches.count {
        case 0: return .missing
        case 1: return .found(matches[0])
        default: return .ambiguous(matches.map(\.workspace))
        }
    }

    /// The issues `names` names unambiguously.
    func found(_ names: [String]) -> [RoadmapIssue] {
        names.compactMap { if case .found(let issue) = find($0) { issue } else { nil } }
    }

    /// The issue as the roadmap writes it: its identifier, with its
    /// workspace when another workspace has the same identifier.
    func display(_ issue: RoadmapIssue) -> String {
        shared.contains(issue.identifier.rawValue.uppercased()) ? "\(issue.workspace):\(issue.identifier)" : issue.identifier.rawValue
    }
}

/// What a roadmap session writes.
struct RoadmapOutput: Decodable, Sendable, Equatable {
    var steps: [Step]
    var actions: [Action]?
    var triage: [Note]?

    struct Step: Decodable, Sendable, Equatable {
        var work: String
        var issues: [String]?
        var who: [String]
        var why: String?
    }

    struct Action: Decodable, Sendable, Equatable {
        var text: String
        var step: Int?
        var issues: [String]?
    }

    struct Note: Decodable, Sendable, Equatable {
        var text: String
        var issues: [String]?
    }

    static func decoded(from data: Data) throws -> RoadmapOutput {
        try JSONDecoder().decode(RoadmapOutput.self, from: data)
    }
}

/// A roadmap session running, so that no other starts beside it.
struct RoadmapBuild: Codable, Sendable, Equatable {
    var sessionId: ClaudeSession.ID
    var startedAt: Date
    var pid: Int32?
    var processStartedAt: Date?

    var isRunning: Bool { AgentRunner.isRunning(pid: pid, startedAt: processStartedAt) }
}

/// The file the roadmaps are kept in. The daemon and `superlinear roadmap`
/// both build roadmaps, and only the daemon writes the state file, so they
/// are kept apart from it, as `superlinear plan`'s jobs are.
struct RoadmapRecord: Codable, Sendable, Equatable {
    /// The latest roadmap of each set of workspaces, by `key(_:)`.
    var roadmaps: [String: Roadmap] = [:]
    /// The sessions building them now, by the same key.
    var building: [String: RoadmapBuild] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roadmaps = try container.decodeIfPresent([String: Roadmap].self, forKey: .roadmaps) ?? [:]
        building = try container.decodeIfPresent([String: RoadmapBuild].self, forKey: .building) ?? [:]
    }

    /// The key of the roadmap of `workspaces`, whatever their order.
    static func key(_ workspaces: [String]) -> String { workspaces.sorted().joined(separator: ",") }

    static func fileURL(home: String = Paths.home) -> URL {
        URL(fileURLWithPath: "\(home)/.local/share/superlinear/roadmap.json")
    }

    static func load(from url: URL = fileURL()) -> RoadmapRecord {
        guard let data = try? Data(contentsOf: url) else { return RoadmapRecord() }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(RoadmapRecord.self, from: data)
        } catch {
            print("[superlinear] Could not read \(url.path), starting with no roadmap: \(error)")
            return RoadmapRecord()
        }
    }

    func save(to url: URL = fileURL()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let tmpURL = url.appendingPathExtension("tmp")
        try encoder.encode(self).write(to: tmpURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
    }

    /// The line at the top of `superlinear status`: when the roadmap of
    /// `workspaces` was last built and how many actions it lists for the owner.
    func pointer(workspaces: [String], now: Date) -> String {
        let key = Self.key(workspaces)
        let building = building[key].map { $0.isRunning } ?? false
        guard let roadmap = roadmaps[key] else {
            return building ? "Roadmap: being built now; see `superlinear roadmap` in a few minutes"
                : "Roadmap: none built yet; `superlinear roadmap` builds one"
        }
        let count = roadmap.actions.count
        var line = "Roadmap: built \(StatusTime.rendered(roadmap.builtAt, now: now)), "
            + (count == 0 ? "nothing for you to do" : "\(count) action\(count == 1 ? "" : "s") for you")
            + "; see `superlinear roadmap`"
        if building { line += " (a new one is being built)" }
        return line
    }
}
