import AppKit
import Foundation

/// Nudges the Codex CLI into renewing its own OAuth token.
///
/// Same contract as `ClaudeCLI`: the refresh token in `~/.codex/auth.json` rotates
/// on every redemption, so redeeming it ourselves would strand the CLI with a dead
/// login. Instead we ask the CLI a question that forces it to load — and, when
/// stale, refresh — its own credentials, then re-read the file.
///
/// The question is asked over the CLI's `app-server` JSON-RPC mode (read-only,
/// untrusted sandbox), because unlike an interactive command it needs no TTY and
/// exits cleanly when we close it. `account/rateLimits/read` touches no inference.
enum CodexCLI {
    /// The desktop app's bundled CLI comes last: a standalone install is likelier
    /// to be current, but the bundle is what's left when the Homebrew cask migrates
    /// to the app and leaves `/opt/homebrew/bin/codex` a dangling symlink (which
    /// `isExecutableFile` rejects, so a broken link falls through cleanly).
    private static let candidates = [
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        "\(NSHomeDirectory())/.local/bin/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
    ]

    static var executable: URL? {
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// The three lines that make the app-server load its credentials and answer.
    private static let script = [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"claude-stats","version":"1.0"}}}"#,
        #"{"jsonrpc":"2.0","method":"initialized"}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read"}"#,
    ].joined(separator: "\n") + "\n"

    /// Returns once the rate-limit request is answered (proof the CLI got as far
    /// as loading and, if needed, refreshing its auth), or false on timeout. The
    /// caller decides whether the token on disk actually moved.
    static func refreshAuth(timeout: TimeInterval = 30) async -> Bool {
        guard let executable else { return false }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["-s", "read-only", "-a", "untrusted", "app-server"]

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = NSHomeDirectory()
        environment["USER"] = NSUserName()
        environment["LOGNAME"] = NSUserName()
        environment["PATH"] = [
            executable.deletingLastPathComponent().path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ].joined(separator: ":")
        process.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        // Discarded, not piped: an unread pipe fills at ~64KB and a chatty server
        // (RUST_LOG et al. are inherited) would deadlock against it mid-answer.
        process.standardError = FileHandle.nullDevice

        return await withCheckedContinuation { continuation in
            let resumed = Resumed()
            let buffer = LineBuffer()

            @Sendable func finish(_ ok: Bool) {
                guard resumed.claim() else { return }
                stdout.fileHandleForReading.readabilityHandler = nil
                if process.isRunning { process.terminate() }
                continuation.resume(returning: ok)
            }

            // The server keeps running until told otherwise, so success is spotting
            // the answer to request 2 in the stream, not process exit.
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { finish(false); return }  // stdout closed
                if buffer.append(data).contains(where: { $0.contains(#""id":2"#) }) {
                    finish(true)
                }
            }

            process.terminationHandler = { _ in finish(false) }

            do {
                try process.run()
                // The throwing write matters: the plain one raises an ObjC
                // exception if the CLI dies before reading, which Swift can't catch.
                try stdin.fileHandleForWriting.write(contentsOf: Data(script.utf8))
            } catch {
                finish(false)
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(false)
            }
        }
    }

    /// Opens an interactive sign-in in Terminal, for when the refresh token itself
    /// has expired and only a human can fix it.
    static func openInteractiveLogin() {
        guard let executable else { return }

        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-stats-codex-login.command")
        let body = """
        #!/bin/bash
        echo "Renewing the Codex login that Claude Stats reads from…"
        "\(executable.path)" login
        """

        guard (try? body.write(to: script, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }
}

/// Accumulates stdout chunks and hands back only complete lines, so a JSON
/// response split across reads is still recognised.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending.prefix(upTo: newline)
            pending.removeSubrange(...newline)
            if let text = String(data: line, encoding: .utf8) { lines.append(text) }
        }
        return lines
    }
}
