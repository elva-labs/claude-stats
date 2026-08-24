import AppKit

/// A single limit, shaped for display.
struct Gauge {
    let shortLabel: String   // "S", "W", "F" — what goes in the menu bar
    let longLabel: String    // "Session (5h)" — what goes in the dropdown
    let seriesKey: String    // stable identity for this quota's recorded history
    let percent: Int
    let severity: Severity
    let resetsAt: Date?
    let sortKey: Int
    /// Spent — there is nothing left to report as a percentage, only a wait.
    let isExhausted: Bool
    /// How much history the row's trend line covers.
    let trendWindow: TimeInterval

    enum Severity {
        case normal, warning, critical
    }

    /// Where this quota sits on the green → red scale.
    var color: NSColor { color(alpha: 1) }

    func color(alpha: CGFloat) -> NSColor {
        Grade.color(percent: percent, severity: severity, alpha: alpha)
    }

    init(limit: Limit) {
        let modelName = limit.scope?.model?.displayName
        let isSession = (limit.group ?? limit.kind).hasPrefix("session")

        seriesKey = limit.seriesKey
        // How far back the trend reaches: one full window, so the trace covers the
        // quota's own cycle rather than an arbitrary slice of it.
        trendWindow = isSession ? 5 * 3_600 : 7 * 86_400

        if let modelName, let initial = modelName.first {
            shortLabel = String(initial).uppercased()
        } else {
            shortLabel = isSession ? "S" : "W"
        }

        switch limit.kind {
        case "session":
            longLabel = modelName.map { "Session · \($0)" } ?? "Session (5h)"
        case "weekly_all":
            longLabel = "Weekly · all models"
        case "weekly_scoped":
            longLabel = modelName.map { "Weekly · \($0)" } ?? "Weekly · scoped"
        default:
            let pretty = limit.kind
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
            longLabel = modelName.map { "\(pretty) · \($0)" } ?? pretty
        }

        percent = Int(limit.percent.rounded())
        resetsAt = limit.resetsAt

        // Trust the server's severity, but never show green when the number is red.
        let fromServer: Severity? = switch limit.severity {
        case "warning": .warning
        case "critical", "exceeded", "blocked": .critical
        case "normal": Severity.normal
        default: nil
        }
        let fromPercent: Severity = percent >= 95 ? .critical : (percent >= 80 ? .warning : .normal)
        severity = max(fromServer ?? .normal, fromPercent)

        // The API has no documented "spent" flag, so trust the number first and
        // treat a handful of plausible severity words as a belt-and-braces signal
        // in case a limit is ever reported as blocked below 100%.
        isExhausted = percent >= 100
            || ["exceeded", "blocked", "reached", "depleted"].contains(limit.severity ?? "")

        // Session limits first, then all-model weekly, then per-model weekly.
        sortKey = isSession ? 0 : (limit.kind == "weekly_all" ? 1 : 2)
    }

    /// Compact time until this quota is usable again — `47m`, `1h12m`, `2d14h`.
    /// Deliberately terse: it takes the place of the percentage in the menu bar.
    func eta(now: Date = Date()) -> String? {
        guard let resetsAt else { return nil }
        let remaining = Int(resetsAt.timeIntervalSince(now).rounded())
        guard remaining > 0 else { return "soon" }

        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3600
        let minutes = (remaining % 3600) / 60

        if days > 0 { return "\(days)d\(hours)h" }
        if hours > 0 { return "\(hours)h\(minutes)m" }
        return minutes > 0 ? "\(minutes)m" : "<1m"
    }

    /// "resets in 1h 12m", or an absolute time once it is more than a day out.
    func resetDescription(now: Date = Date()) -> String? {
        guard let resetsAt else { return nil }
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds > 0 else { return "resetting…" }

        if seconds < 86_400 {
            let hours = Int(seconds) / 3600
            let minutes = (Int(seconds) % 3600) / 60
            let span = hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
            return "resets in \(span)"
        }

        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        return "resets \(f.string(from: resetsAt))"
    }
}

extension Gauge.Severity: Comparable {
    private var rank: Int {
        switch self {
        case .normal: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}
