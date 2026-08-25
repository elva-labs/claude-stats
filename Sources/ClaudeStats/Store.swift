import Foundation

/// Remembers the last successful reading on disk.
///
/// Without this the app opens blank after every launch and shows nothing at all
/// whenever the network is down or the endpoint is throttling — which is precisely
/// when you are most likely to be looking. Stale figures clearly marked as stale beat
/// an empty menu bar.
enum Store {
    struct Snapshot: Codable {
        let savedAt: Date
        let limits: [Limit]
    }

    /// One snapshot per provider, keyed by `Provider.rawValue`. Kept as a map so a
    /// poll that only reached one endpoint doesn't discard the other's reading.
    private struct State: Codable {
        var providers: [String: Snapshot]
    }

    static let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/ClaudeStats/state.json")

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        // ISO8601 so it round-trips through the same parser the API responses use.
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = ISO8601.parse(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Unrecognised timestamp: \(raw)"
                )
            }
            return date
        }
        return d
    }

    static func save(limits: [Limit], for provider: Provider) {
        var state = loadState() ?? State(providers: [:])
        state.providers[provider.rawValue] = Snapshot(savedAt: Date(), limits: limits)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(state).write(to: url, options: .atomic)
        } catch {
            Log.write("state save failed: \(error.localizedDescription)")
        }
    }

    static func load(_ provider: Provider) -> Snapshot? {
        loadState()?.providers[provider.rawValue]
    }

    private static func loadState() -> State? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let state = try? decoder.decode(State.self, from: data) { return state }
        // Files written before Codex support hold a bare Claude snapshot.
        do {
            let legacy = try decoder.decode(Snapshot.self, from: data)
            return State(providers: [Provider.claude.rawValue: legacy])
        } catch {
            Log.write("state load failed: \(error.localizedDescription)")
            return nil
        }
    }
}

/// How much to trust what is on screen. Age is a better signal than a boolean
/// "offline" flag: a reading four minutes old during a brief blip is still worth
/// reading at full strength, while one from this morning is not.
enum Staleness {
    case fresh    // under 5 minutes
    case aging    // under 30 minutes
    case stale    // under 6 hours
    case ancient  // older still

    init(age: TimeInterval) {
        switch age {
        case ..<300: self = .fresh
        case ..<1_800: self = .aging
        case ..<21_600: self = .stale
        default: self = .ancient
        }
    }

    init(lastUpdated: Date?) {
        guard let lastUpdated else { self = .ancient; return }
        self.init(age: Date().timeIntervalSince(lastUpdated))
    }

    /// Opacity for the readout. Older data recedes rather than disappearing, so the
    /// menu bar always shows *something* while making clear how much to trust it.
    var opacity: CGFloat {
        switch self {
        case .fresh: return 1.0
        case .aging: return 0.8
        case .stale: return 0.6
        case .ancient: return 0.45
        }
    }

    /// Whether the age is worth spelling out next to the numbers.
    var warrantsAgeLabel: Bool {
        switch self {
        case .fresh, .aging: return false
        case .stale, .ancient: return true
        }
    }

    static func compactAge(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds >= 86_400 { return "\(seconds / 86_400)d" }
        if seconds >= 3_600 { return "\(seconds / 3_600)h" }
        return "\(max(1, seconds / 60))m"
    }
}
