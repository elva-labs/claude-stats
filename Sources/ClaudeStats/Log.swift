import Foundation

/// A tiny append-only log at `~/Library/Logs/ClaudeStats.log`.
///
/// A menu bar app has nowhere to show a stack trace — the status item has room for a
/// warning glyph and little else — so anything worth diagnosing has to be written
/// down somewhere a human can read it afterwards.
enum Log {
    static let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/ClaudeStats.log")

    private static let queue = DispatchQueue(label: "com.tobias.claudestats.log")
    private static let maxBytes = 256 * 1024

    static func write(_ message: String) {
        queue.async {
            let stamp = ISO8601DateFormatter().string(from: Date())
            guard let data = "\(stamp)  \(message)\n".data(using: .utf8) else { return }

            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                try? fm.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? data.write(to: url)
                return
            }

            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)

            // Truncate rather than rotate: this is a breadcrumb trail, not an archive.
            if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > maxBytes {
                try? handle.truncate(atOffset: 0)
            }
        }
    }
}
