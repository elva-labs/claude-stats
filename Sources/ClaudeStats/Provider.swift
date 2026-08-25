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
/// `nil` (nothing stored) means the default: every Claude gauge, no Codex ones —
/// the app's original behaviour. The set only materialises once the user toggles
/// a row, and from then on newly appearing gauges stay off until chosen.
enum BarSelection {
    private static let key = "barGaugeIDs"

    private static var stored: Set<String>? {
        get { (UserDefaults.standard.array(forKey: key) as? [String]).map(Set.init) }
        set { UserDefaults.standard.set(newValue.map(Array.init), forKey: key) }
    }

    static func shows(_ gauge: Gauge) -> Bool {
        guard let stored else { return gauge.provider == .claude }
        return stored.contains(gauge.id)
    }

    /// Flip one gauge, materialising the default selection on first use so the
    /// other checkmarks don't jump.
    static func toggle(_ id: String, current: [Gauge]) {
        var set = stored ?? Set(current.filter { $0.provider == .claude }.map(\.id))
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        stored = set
    }
}
