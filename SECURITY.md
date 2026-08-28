# Security

## What this app touches

Claude Stats reads credentials that other tools own. Being precise about it:

- **Claude Code's OAuth access token**, from the login keychain item
  `Claude Code-credentials`, read via `/usr/bin/security`. Read-only.
- **The Codex CLI's OAuth access token**, from `~/.codex/auth.json`. Read-only.
- It **never reads, stores, or redeems a refresh token**, and never writes to
  either credential store. Renewal is delegated to the owning CLI.

Those tokens are sent, over HTTPS, only to the usage endpoints of their own
issuers (`api.anthropic.com` and `chatgpt.com`) — nowhere else. No telemetry,
no third-party services. Everything the app persists locally
(`~/Library/Application Support/ClaudeStats/`, `~/Library/Logs/ClaudeStats.log`)
contains percentages and timestamps, never tokens.

Releases are signed with Elva's Developer ID certificate and notarized by
Apple, both done in CI. You can verify a download with
`spctl -a -vv "/Applications/Claude Stats.app"`, which should report
`source=Notarized Developer ID` and
`origin=Developer ID Application: Elva Group AB (WL4K563SDJ)`.

## Reporting a vulnerability

Please **do not open a public issue** for anything security-sensitive —
especially anything involving token handling or the CLI nudges.

Use GitHub's private reporting:
[Report a vulnerability](https://github.com/elva-labs/claude-stats/security/advisories/new).
You'll get an acknowledgement within a few working days, and we'll keep you
informed as it's triaged and fixed. Credit is given in the release notes
unless you'd rather not.

## Supported versions

Only the latest release is supported; fixes ship as a new release rather than
being backported.
