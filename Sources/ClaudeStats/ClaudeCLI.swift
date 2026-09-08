import AppKit
import Foundation

/// Locates the Claude Code CLI and opens an interactive sign-in with it.
///
/// The app deliberately never refreshes the token itself. The refresh response
/// carries a new `refresh_token`, so refresh tokens rotate — a second client doing
/// its own refresh would invalidate the one Claude Code holds and break your real
/// login. Nor can the CLI be asked to renew on the app's behalf: `claude auth status`
/// only reports what is stored, and anything that does renew is a real prompt, which
/// costs the quota this app exists to report on. So an expired access token is simply
/// waited out until Claude Code's next run writes a fresh one (see `UsageAPI.fetch`).
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
