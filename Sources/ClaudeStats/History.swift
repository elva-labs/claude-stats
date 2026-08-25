import Foundation

/// An append-only trail of past readings, so a row can show where a quota came from
/// and not just where it is.
///
/// `Store` deliberately keeps one snapshot and overwrites it; that answers "what do I
/// show before the first fetch lands". A trend is a different question, and needs
/// every reading kept rather than the newest one. The file is a line per poll, which
/// makes appending the common case and rewriting the rare one.
enum History {
    /// One reading of one quota.
    struct Sample {
        let at: Date
        let percent: Int
        let resetsAt: Date?
    }

    static let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/ClaudeStats/history.ndjson")

    /// Long enough to cover a full weekly window twice over, so a fresh week always
    /// has the previous one behind it.
    private static let retention: TimeInterval = 16 * 86_400

    /// A backstop for the retention sweep. Roughly 5× what a fortnight of polling
    /// actually costs, so hitting it means something has gone wrong, not that the
    /// window was set too generously.
    private static let maxBytes = 1_024 * 1_024

    // MARK: Wire format

    /// Short keys because these lines are written every few minutes forever, and the
    /// file is never read by anything but this app.
    private struct Row: Codable {
        let t: Int              // sampled at, epoch seconds
        let v: [Entry]

        struct Entry: Codable {
            let k: String       // series key
            let p: Int          // percent
            let r: Int?         // resets at, epoch seconds
        }
    }

    // Parsing the whole file on every menu open would be wasteful when the app that
    // wrote it is the one reading it — keep it in memory and append to both.
    nonisolated(unsafe) private static var rows: [Row]?

    // MARK: Reading

    /// Every reading of one quota inside the given window, oldest first.
    static func series(for key: String, since: Date) -> [Sample] {
        let cutoff = Int(since.timeIntervalSince1970)
        return loaded().compactMap { row in
            guard row.t >= cutoff, let entry = row.v.first(where: { $0.k == key }) else { return nil }
            return Sample(
                at: Date(timeIntervalSince1970: TimeInterval(row.t)),
                percent: entry.p,
                resetsAt: entry.r.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )
        }
    }

    // MARK: Writing

    static func append(limits: [Limit]) {
        let row = Row(
            t: Int(Date().timeIntervalSince1970),
            v: limits.map {
                Row.Entry(
                    k: $0.seriesKey,
                    p: Int($0.percent.rounded()),
                    r: $0.resetsAt.map { at in Int(at.timeIntervalSince1970) }
                )
            }
        )
        guard !row.v.isEmpty, let line = encode(row) else { return }

        var all = loaded()
        all.append(row)

        // Rows are written in time order, so only the oldest can have aged out.
        let cutoff = Int(Date().addingTimeInterval(-retention).timeIntervalSince1970)
        let hasExpired = (all.first?.t ?? cutoff) < cutoff
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0

        if hasExpired || size > maxBytes {
            all = all.filter { $0.t >= cutoff }
            rows = all
            rewrite(all)
        } else {
            rows = all
            appendLine(line)
        }
    }

    // MARK: Disk

    private static func loaded() -> [Row] {
        if let rows { return rows }
        let parsed = readFromDisk()
        rows = parsed
        return parsed
    }

    private static func readFromDisk() -> [Row] {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        // A truncated last line — a crash mid-write — costs that one reading and
        // nothing else, so skip whatever doesn't parse rather than starting over.
        return text.split(separator: "\n").compactMap { line in
            guard let raw = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(Row.self, from: raw)
        }
    }

    private static func encode(_ row: Row) -> Data? {
        try? JSONEncoder().encode(row)
    }

    private static func appendLine(_ line: Data) {
        let fm = FileManager.default
        var payload = line
        payload.append(0x0a)

        guard fm.fileExists(atPath: url.path) else {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? payload.write(to: url)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            Log.write("history append failed to open the file")
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: payload)
    }

    private static func rewrite(_ all: [Row]) {
        var payload = Data()
        for row in all {
            guard let line = encode(row) else { continue }
            payload.append(line)
            payload.append(0x0a)
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try payload.write(to: url, options: .atomic)
        } catch {
            Log.write("history rewrite failed: \(error.localizedDescription)")
        }
    }
}

extension Limit {
    /// Stable identity for one quota across polls. The kind alone collides once a
    /// plan has more than one per-model weekly limit, so the model qualifies it.
    var seriesKey: String {
        guard let model = scope?.model?.id ?? scope?.model?.displayName else { return kind }
        return "\(kind):\(model)"
    }
}
