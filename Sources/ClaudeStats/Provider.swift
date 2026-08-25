import Foundation

/// A source of usage figures. Claude is the reason this app exists; Codex rides
/// along when its CLI credentials are present on the machine.
enum Provider: String, Codable, CaseIterable {
    case claude
    case codex

    /// Section header in the dropdown.
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "OpenAI"
        }
    }

    /// Marker shown in the menu bar when gauges from more than one provider are
    /// visible at once and the letters alone would be ambiguous (both providers
    /// have a session and a weekly quota).
    var barTag: String {
        switch self {
        case .claude: return "CC"
        case .codex: return "GPT"
        }
    }
}

/// Which gauges appear in the menu bar itself. Everything always appears in the
/// dropdown; this only decides what takes up bar space.
///
/// Only explicit choices are stored, as per-gauge overrides of the default rule
/// (Claude in, Codex out). Gauges never toggled keep following the rule, so a new
/// Claude quota appearing on the plan shows up in the bar without asking, and a
/// toggle made while one provider happens to be failing can't freeze a snapshot
/// of the moment into the settings.
enum BarSelection {
    private static let key = "barGaugeOverrides"

    private static var overrides: [String: Bool] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func shows(_ gauge: Gauge) -> Bool {
        overrides[gauge.id] ?? (gauge.provider == .claude)
    }

    static func toggle(_ gauge: Gauge) {
        var map = overrides
        map[gauge.id] = !shows(gauge)
        overrides = map
    }
}
