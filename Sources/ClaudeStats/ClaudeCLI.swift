import AppKit
import Foundation

/// Nudges the Claude Code CLI into renewing its own OAuth token.
///
/// The app deliberately never refreshes the token itself. The refresh response
/// carries a new `refresh_token`, so refresh tokens rotate — a second client doing
/// its own refresh would invalidate the one Claude Code holds and break your real
/// login. Instead we ask the CLI to do it and re-read the result, leaving Claude Code
/// the sole owner of the credential.
///
/// `auth status` is used rather than a prompt because it touches no inference and so
/// costs none of the quota this app exists to report on.
enum ClaudeCLI {
    /// Where the CLI might live. A GUI app launched by Finder or launchd inherits a
    /// bare PATH, so the binary has to be found by absolute path.
    private static let candidates = [
        "\(NSHomeDirectory())/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "\(NSHomeDirectory())/.claude/local/claude",
    ]

    static var executable: URL? {
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Ask the CLI to validate its session, which renews the token when it is stale.
    /// Returns whether the command completed cleanly; the caller decides whether the
    /// keychain actually moved.
    static func refreshAuth(timeout: TimeInterval = 20) async -> Bool {
        guard let executable else { return false }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["auth", "status", "--json"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        // Keep it non-interactive: no TTY, so it can never sit waiting for input.
        process.standardInput = FileHandle.nullDevice

        return await withCheckedContinuation { continuation in
            let resumed = Resumed()

            process.terminationHandler = { proc in
                guard resumed.claim() else { return }
                continuation.resume(returning: proc.terminationStatus == 0)
            }

            do {
                try process.run()
            } catch {
                if resumed.claim() { continuation.resume(returning: false) }
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                process.terminate()
                if resumed.claim() { continuation.resume(returning: false) }
            }
        }
    }

    /// Opens an interactive sign-in in Terminal, for when the refresh token itself
    /// has expired and only a human can fix it.
    static func openInteractiveLogin() {
        guard let executable else { return }

        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-stats-login.command")
        let body = """
        #!/bin/bash
        echo "Renewing the Claude Code login that Claude Stats reads from…"
        "\(executable.path)" auth login
        """

        // A .command file opens in Terminal without needing Automation permission,
        // which an AppleScript-driven approach would prompt for.
        guard (try? body.write(to: script, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }
}

/// One-shot latch so a continuation is resumed exactly once, whichever of the
/// termination handler or the timeout gets there first.
private final class Resumed: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

