import Foundation

/// The menu bar's numbers on stdout, for scripts, status lines and agents that
/// want to know how much quota is left before they start something expensive.
///
///     ClaudeStats usage            # human-readable
///     ClaudeStats usage --json     # machine-readable
///
/// Cache first. The endpoints throttle readily and the app already keeps its own
/// requests a minute apart, so a script asking every few seconds must not turn
/// into a request every few seconds. A reading taken within `--max-age` — by the
/// app or by an earlier invocation — is served from `state.json`; only an older
/// one goes to the network. A fetch that fails falls back to whatever is cached,
/// marked as such, so the caller always gets the best number available and can
/// see how far to trust it.
enum CLI {
    // MARK: Options

    struct Options: Equatable {
        enum Command: Equatable {
            case usage, help, version
        }

        var command: Command = .usage
        var json = false
        /// `nil` means Claude, plus Codex when this machine has a Codex login.
        var providers: [Provider]?
        /// How old a cached reading may be before the network is asked.
        /// `0` always fetches; `.infinity` never does.
        var maxAge: TimeInterval = defaultMaxAge
    }

    /// Matches the app's own floor between requests (`minimumSpacing`), so a
    /// script polling in a tight loop costs the endpoint no more than the app does.
    static let defaultMaxAge: TimeInterval = 60

    enum UsageError: LocalizedError, Equatable {
        case unknownArgument(String)
        case missingValue(String)
        case badValue(String, String)
        case conflict(String)

        var errorDescription: String? {
            switch self {
            case .unknownArgument(let arg): return "Unknown argument: \(arg)"
            case .missingValue(let flag): return "\(flag) needs a value"
            case .badValue(let flag, let value): return "Bad value for \(flag): \(value)"
            case .conflict(let text): return text
            }
        }
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var freshness: String?
        var rest = arguments[...]

        func take(_ flag: String) throws -> String {
            guard let value = rest.popFirst() else { throw UsageError.missingValue(flag) }
            return value
        }
        func setFreshness(_ flag: String, _ age: TimeInterval) throws {
            if let earlier = freshness, earlier != flag {
                throw UsageError.conflict("\(earlier) and \(flag) contradict each other")
            }
            freshness = flag
            options.maxAge = age
        }

        while let argument = rest.popFirst() {
            switch argument {
            case "usage":
                options.command = .usage
            case "-h", "--help", "help":
                options.command = .help
            case "-V", "--version", "version":
                options.command = .version
            case "--json":
                options.json = true
            case "--cached":
                try setFreshness(argument, .infinity)
            case "--fresh":
                try setFreshness(argument, 0)
            case "--max-age":
                let raw = try take(argument)
                guard let seconds = TimeInterval(raw), seconds >= 0 else {
                    throw UsageError.badValue(argument, raw)
                }
                try setFreshness(argument, seconds)
            case "--provider":
                let raw = try take(argument)
                var chosen = options.providers ?? []
                for name in raw.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                    if name == "all" {
                        chosen.append(contentsOf: Provider.allCases)
                    } else if let provider = Provider(rawValue: name.lowercased()) {
                        chosen.append(provider)
                    } else {
                        throw UsageError.badValue(argument, name)
                    }
                }
                // Keep first-mentioned order, drop repeats.
                var seen = Set<Provider>()
                options.providers = chosen.filter { seen.insert($0).inserted }
            default:
                throw UsageError.unknownArgument(argument)
            }
        }
        return options
    }

    static let help = """
    Usage: ClaudeStats usage [options]

    Prints the usage quotas the menu bar shows: Claude always, OpenAI/Codex when
    this machine has a Codex login.

    Options:
      --json               machine-readable output (see below)
      --provider NAME      claude, codex, or all — repeatable or comma-separated
      --max-age SECONDS    serve a cached reading up to this old (default \(Int(defaultMaxAge)))
      --cached             never contact the network; cached reading or nothing
      --fresh              always contact the network
      -h, --help           this text
      -V, --version        version

    The reading comes from the same cache the app keeps, so a script polling in a
    tight loop costs the usage endpoints nothing extra. When a fetch fails the
    last cached reading is returned instead, with "source": "cache" and "error"
    set, so the numbers are always the best available.

    JSON shape:
      {"generated_at": …, "providers": {"claude": {"source": "live" | "cache",
       "fetched_at": …, "age_seconds": …, "error": null | "…",
       "limits": [{"kind": "session", "label": "Session (5h)", "percent": 46,
                   "remaining_percent": 54, "severity": "normal", "exhausted": false,
                   "resets_at": …, "resets_in_seconds": …}, …]}}}

    Exit status: 0 when every requested provider produced a reading, 1 when one
    could not, 2 for a usage error.
    """

    // MARK: Entry

    static func main(_ arguments: [String]) async -> Int32 {
        let options: Options
        do {
            options = try parse(arguments)
        } catch {
            stderr("ClaudeStats: \(error.localizedDescription)\n\(help)")
            return 2
        }

        switch options.command {
        case .help:
            print(help)
            return 0
        case .version:
            print(version)
            return 0
        case .usage:
            let providers = options.providers ?? ([.claude] + (CodexAPI.isAvailable ? [.codex] : []))
            let outcomes = await fetch(providers, maxAge: options.maxAge)
            let report = Report(providers: providers, outcomes: outcomes)
            print(options.json ? report.json() : report.text())
            // Log lines are written on a background queue; give them a chance to land.
            Log.flush()
            return report.exitStatus
        }
    }

    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0-dev"
    }

    private static func stderr(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    // MARK: Fetching

    struct Reading {
        enum Source: String, Encodable {
            case live, cache
        }

        let source: Source
        let at: Date
        let limits: [Limit]
        let extraUsage: ExtraUsage?
        let footnote: String?
    }

    struct Outcome {
        var reading: Reading?
        var error: String?
    }

    static func fetch(_ providers: [Provider], maxAge: TimeInterval) async -> [Provider: Outcome] {
        await withTaskGroup(of: (Provider, Outcome).self) { group in
            for provider in providers {
                group.addTask { (provider, await outcome(for: provider, maxAge: maxAge)) }
            }
            var outcomes: [Provider: Outcome] = [:]
            for await (provider, outcome) in group { outcomes[provider] = outcome }
            return outcomes
        }
    }

    private static func outcome(for provider: Provider, maxAge: TimeInterval, now: Date = Date()) async -> Outcome {
        let cached = Store.load(provider).map {
            Reading(source: .cache, at: $0.savedAt, limits: $0.limits, extraUsage: nil, footnote: nil)
        }
        if let cached, now.timeIntervalSince(cached.at) <= maxAge {
            return Outcome(reading: cached)
        }
        if maxAge == .infinity {
            return Outcome(reading: nil, error: "No cached reading for \(provider.displayName) yet.")
        }

        do {
            let live: Reading
            switch provider {
            case .claude:
                let result = try await UsageAPI.fetch()
                live = Reading(
                    source: .live, at: Date(), limits: result.usage.limits,
                    extraUsage: result.usage.extraUsage, footnote: nil
                )
            case .codex:
                let result = try await CodexAPI.fetch()
                live = Reading(
                    source: .live, at: Date(), limits: result.limits,
                    extraUsage: nil, footnote: result.footnote
                )
            }
            // Recorded like any poll, so the next invocation — and the app's trend
            // lines — benefit from the request just spent.
            Store.save(limits: live.limits, for: provider)
            History.append(limits: live.limits, provider: provider)
            return Outcome(reading: live)
        } catch {
            return Outcome(reading: cached, error: error.localizedDescription)
        }
    }

    // MARK: Report

    /// What gets printed. Built from outcomes rather than printed straight from
    /// them so the shape can be tested without a network or a cache on disk.
    struct Report: Encodable {
        let generatedAt: Date
        let providers: [String: ProviderReport]

        /// Requested order, for the text rendering; JSON objects carry none.
        private let order: [Provider]

        private enum CodingKeys: String, CodingKey {
            case generatedAt, providers
        }

        init(providers: [Provider], outcomes: [Provider: Outcome], now: Date = Date()) {
            generatedAt = now
            order = providers
            var map: [String: ProviderReport] = [:]
            for provider in providers {
                map[provider.rawValue] = ProviderReport(
                    provider: provider,
                    outcome: outcomes[provider] ?? Outcome(),
                    now: now
                )
            }
            self.providers = map
        }

        /// A provider without any reading — no cache and a failed fetch — is the
        /// one case a script can't do anything useful with.
        var exitStatus: Int32 {
            providers.values.contains { $0.source == nil } ? 1 : 0
        }

        func json() -> String {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
                return "{}"
            }
            return text
        }

        func text() -> String {
            var lines: [String] = []
            let sectioned = order.count > 1
            for provider in order {
                guard let section = providers[provider.rawValue] else { continue }
                if sectioned {
                    var header = section.name
                    if let source = section.source {
                        header += "  (\(source.rawValue)"
                        if let age = section.ageSeconds { header += ", \(Report.age(age)) ago" }
                        header += ")"
                    }
                    lines.append(header)
                }
                if let error = section.error {
                    lines.append("  ! \(error)")
                }
                let indent = sectioned ? "  " : ""
                let width = section.limits.map(\.label.count).max() ?? 0
                for limit in section.limits {
                    var line = indent + limit.label.padding(toLength: width, withPad: " ", startingAt: 0)
                    line += "  " + String(repeating: " ", count: max(0, 3 - String(limit.percent).count)) + "\(limit.percent)%"
                    if let reset = limit.resetsAt {
                        line += "  " + Gauge.resetDescription(resetsAt: reset, now: generatedAt)
                    }
                    lines.append(line)
                }
                if let extra = section.extraUsage { lines.append(indent + extra.text) }
                if let note = section.note { lines.append(indent + note) }
                if !sectioned, let source = section.source {
                    var footer = "Source: \(source.rawValue)"
                    if let age = section.ageSeconds { footer += ", \(Report.age(age)) ago" }
                    lines.append(footer)
                }
            }
            return lines.joined(separator: "\n")
        }

        static func age(_ seconds: Int) -> String {
            if seconds >= 86_400 { return "\(seconds / 86_400)d" }
            if seconds >= 3_600 { return "\(seconds / 3_600)h" }
            if seconds >= 60 { return "\(seconds / 60)m" }
            return "\(seconds)s"
        }
    }

    struct ProviderReport: Encodable {
        let name: String
        let source: Reading.Source?
        let fetchedAt: Date?
        let ageSeconds: Int?
        let error: String?
        let limits: [LimitReport]
        let extraUsage: ExtraUsageReport?
        /// Plan and credits, Codex only.
        let note: String?

        private enum CodingKeys: String, CodingKey {
            case name, source, fetchedAt, ageSeconds, error, limits, extraUsage, note
        }

        /// Every key is always present — `null` rather than absent — so a script
        /// can read `.error` without first checking whether it exists.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(source, forKey: .source)
            try c.encode(fetchedAt, forKey: .fetchedAt)
            try c.encode(ageSeconds, forKey: .ageSeconds)
            try c.encode(error, forKey: .error)
            try c.encode(limits, forKey: .limits)
            try c.encode(extraUsage, forKey: .extraUsage)
            try c.encode(note, forKey: .note)
        }

        init(provider: Provider, outcome: Outcome, now: Date) {
            name = provider.displayName
            error = outcome.error
            source = outcome.reading?.source
            fetchedAt = outcome.reading?.at
            ageSeconds = outcome.reading.map { max(0, Int(now.timeIntervalSince($0.at))) }
            limits = (outcome.reading?.limits ?? [])
                .map { Gauge(limit: $0, provider: provider) }
                .sorted { ($0.sortKey, $0.longLabel) < ($1.sortKey, $1.longLabel) }
                .map { LimitReport(gauge: $0, now: now) }
            extraUsage = outcome.reading?.extraUsage.flatMap(ExtraUsageReport.init)
            note = outcome.reading?.footnote
        }
    }

    struct LimitReport: Encodable {
        let id: String
        let kind: String
        let label: String
        let model: String?
        let percent: Int
        let remainingPercent: Int
        let severity: String
        let exhausted: Bool
        let resetsAt: Date?
        let resetsInSeconds: Int?

        private enum CodingKeys: String, CodingKey {
            case id, kind, label, model, percent, remainingPercent, severity, exhausted, resetsAt, resetsInSeconds
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(kind, forKey: .kind)
            try c.encode(label, forKey: .label)
            try c.encode(model, forKey: .model)
            try c.encode(percent, forKey: .percent)
            try c.encode(remainingPercent, forKey: .remainingPercent)
            try c.encode(severity, forKey: .severity)
            try c.encode(exhausted, forKey: .exhausted)
            try c.encode(resetsAt, forKey: .resetsAt)
            try c.encode(resetsInSeconds, forKey: .resetsInSeconds)
        }

        init(gauge: Gauge, now: Date) {
            id = gauge.id
            kind = gauge.kind
            label = gauge.longLabel
            model = gauge.scopeName
            percent = gauge.percent
            remainingPercent = max(0, 100 - gauge.percent)
            severity = switch gauge.severity {
            case .normal: "normal"
            case .warning: "warning"
            case .critical: "critical"
            }
            exhausted = gauge.isExhausted
            resetsAt = gauge.resetsAt
            resetsInSeconds = gauge.resetsAt.map { max(0, Int($0.timeIntervalSince(now).rounded())) }
        }
    }

    struct ExtraUsageReport: Encodable {
        let utilization: Double?
        let usedCredits: Double?
        let monthlyLimit: Double?
        let currency: String?

        /// Only an enabled extra-usage budget is worth reporting; a disabled one
        /// is the plan's normal state, not a number.
        init?(_ extra: ExtraUsage) {
            guard extra.isEnabled == true else { return nil }
            utilization = extra.utilization
            usedCredits = extra.usedCredits
            monthlyLimit = extra.monthlyLimit
            currency = extra.currency
        }

        var text: String {
            var text = "Extra usage"
            if let used = usedCredits {
                let symbol = currency == "USD" ? "$" : ""
                text += ": \(symbol)\(String(format: "%.2f", used))"
                if let cap = monthlyLimit { text += " of \(symbol)\(String(format: "%.2f", cap))" }
            } else if let pct = utilization {
                text += ": \(Int(pct.rounded()))%"
            }
            return text
        }
    }
}
