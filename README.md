# Claude Stats

[![CI](https://github.com/elva-labs/claude-stats/actions/workflows/ci.yml/badge.svg)](https://github.com/elva-labs/claude-stats/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/elva-labs/claude-stats?display_name=tag)](https://github.com/elva-labs/claude-stats/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey)

A macOS menu bar app that keeps your Claude usage percentages visible at all times —
the same numbers `/usage` shows inside Claude Code. If the machine also has a Codex
login, your OpenAI quotas ride along.

<p align="center">
  <img src="assets/screenshot.png" width="583" alt="Claude Stats dropdown showing Claude and OpenAI usage with meters, trend lines and reset countdowns">
</p>

## Features

- Session and weekly percentages in the menu bar, coloured on a continuous
  green → red scale; a spent quota shows its reset countdown instead of a useless `100%`
- Dropdown with meters, trend sparklines, reset countdowns, and a full chart
  (with burn rate and projected run-out) on click
- OpenAI/Codex quotas alongside Claude when `~/.codex/auth.json` exists
- **Show in Menu Bar** picks which quotas occupy the bar (default: Claude only)
- Adaptive polling: 5–10 min while numbers move, nothing while the screen is
  off, an immediate fetch when you come back, on-demand fetch when the menu opens
- Read-only credentials: borrows the tokens Claude Code and the Codex CLI already
  maintain, never touches a refresh token, never prompts for keychain access
- Survives offline: last reading is cached and fades with age instead of vanishing
- `ClaudeStats usage --json` prints the same numbers for scripts and agents,
  served from the app's cache so polling costs the endpoints nothing extra
- No dependencies, no accounts, no telemetry — Foundation and AppKit only

## Installation

**Requirements:** macOS 14 or later, and a signed-in [Claude Code](https://claude.com/claude-code)
(`claude`) — the app reads its usage through the CLI's login. Codex (`codex login`)
is optional and auto-detected.

### Homebrew

```sh
brew tap elva-labs/elva
brew trust elva-labs/elva   # newer Homebrew refuses third-party taps until trusted
brew install --cask claude-stats
```

### Direct download

Download `Claude-Stats.zip` from the
[latest release](https://github.com/elva-labs/claude-stats/releases/latest), unzip,
and drag `Claude Stats.app` into `/Applications`.

Either way you get a universal binary (Apple Silicon and Intel), signed with Elva's
Developer ID and notarized by Apple, so it opens like any other app.

Tick **Start at Login** in the dropdown if you want it always there.

### Build from source

Requires Xcode (or the Swift toolchain that ships with it).

```sh
git clone https://github.com/elva-labs/claude-stats.git
cd claude-stats
./build.sh
```

`build.sh` compiles, wraps the binary into `Claude Stats.app`, installs it to
`/Applications`, and launches it. Re-running it replaces a running copy.

### Uninstall

`brew uninstall --cask claude-stats` (add `--zap` to remove its data too), or quit the
app, delete `/Applications/Claude Stats.app`, and optionally remove its data: `~/Library/Application Support/ClaudeStats/` and `~/Library/Logs/ClaudeStats.log`.
It never modifies your Claude Code or Codex credentials, so there's nothing to undo there.

## Command line

The app's binary doubles as a command. With no arguments it is the menu bar app;
with `usage` it prints the quotas and exits, so a shell script, a status line or an
agent can check how much is left before starting something expensive.

```sh
alias claude-stats="/Applications/Claude\ Stats.app/Contents/MacOS/ClaudeStats"
# or, for something on PATH:
ln -s "/Applications/Claude Stats.app/Contents/MacOS/ClaudeStats" ~/.local/bin/claude-stats

claude-stats usage
claude-stats usage --json
claude-stats usage --json | jq '.providers.claude.limits[] | select(.kind == "session").percent'
```

```
Claude  (cache, 2m ago)
  Session (5h)          46%  resets in 3h 48m
  Weekly · all models    2%  resets Tue 07:59
  Weekly · Fable         2%  resets Tue 07:59
OpenAI  (cache, 2m ago)
  Session (5h)   16%  resets in 4h 34m
  Weekly          3%  resets Tue 08:26
```

The reading comes from the same cache the app keeps. A reading younger than a
minute (`--max-age`) is served as is; an older one triggers a fetch, which is
recorded so the app and the next call benefit from it. That keeps a script polling
in a tight loop from costing the endpoints any more than the app does — they
throttle readily, and a throttle would hit the menu bar too. `--fresh` always
fetches, `--cached` never does, and `--provider claude` (or `codex`, or `all`)
narrows the output; by default you get Claude plus Codex when it is logged in.

With `--json` every provider carries `source` (`live` or `cache`), `fetched_at`,
`age_seconds`, `error`, and a `limits` array of `kind`, `label`, `percent`,
`remaining_percent`, `severity`, `exhausted`, `resets_at` and `resets_in_seconds`.
Keys are always present, `null` when unknown. When a fetch fails the last cached
reading is returned with `error` set rather than nothing at all, so the exit status
is 0 whenever every requested provider has a reading, 1 when one has none, and 2
for a usage error. `--help` has the details.

The command needs the app installed, not running: it reads the same credentials the
app does and works without a menu bar session.

## How it works

Claude Code stores an OAuth token in the login keychain; the Codex CLI stores one in
`~/.codex/auth.json`. Claude Stats reads those tokens — read-only, re-read on every
poll — and calls the same usage endpoints the CLIs' own status commands use. When a
token goes stale the app nudges the owning CLI to renew it and re-reads the result;
it never redeems a refresh token itself, because refresh tokens rotate and a second
owner would break your actual login.

Tokens go only to their issuers' usage endpoints (`api.anthropic.com`, `chatgpt.com`)
and nowhere else. What the app touches and how to report a problem is spelled out in
[SECURITY.md](SECURITY.md).

The full reasoning — colour scale, trend lines, polling cadence, throttle handling,
file formats — lives in [docs/DESIGN.md](docs/DESIGN.md).

## Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for
the ground rules (the important one: never touch a refresh token) and how to run the
tests.

## License

[MIT](LICENSE) © Elva Labs
