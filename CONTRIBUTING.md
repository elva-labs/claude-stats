# Contributing

Thanks for your interest. Claude Stats is a small, opinionated app, and the
easiest contributions to land are ones that respect the constraints it was
built around — read [docs/DESIGN.md](docs/DESIGN.md) first; it explains why
things are the way they are and will save you a round-trip in review.

## Ground rules

- **Never touch a refresh token.** The app reads access tokens that Claude
  Code and the Codex CLI already maintain, and asks those CLIs to renew them.
  A change that redeems a refresh token itself will not be merged, however
  convenient — it breaks the user's real login (see the design notes).
- **Polling is a budget, not a free resource.** Anything that adds requests
  needs a reason the existing cadence can't cover.
- **The menu bar is small.** New information belongs in the dropdown or the
  chart unless it earns its bar space; the bar's default stays as it is.
- No dependencies. It's Foundation and AppKit, and stays that way.

## Setting up

Requires macOS 14+ and Xcode (for XCTest). If `swift test` reports
`no such module 'XCTest'`, your active toolchain is the Command Line Tools —
either `sudo xcode-select -s /Applications/Xcode.app` or prefix commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

```sh
git clone https://github.com/elva-labs/claude-stats.git
cd claude-stats
swift test        # pure logic: gauges, parsing, staleness, bar rendering
./build.sh        # build, install to /Applications, launch
```

`./build.sh` replaces a running copy, so iterate with it directly.
`~/Library/Logs/ClaudeStats.log` records state transitions while you test.

## Making changes

- Open an issue first for anything beyond a small fix, so we can agree on
  shape before you invest in it.
- Keep the code style of the surrounding file. Comments explain *why*, not
  what; the existing ones set the tone.
- Add or adjust tests for logic that can be tested without a network or a
  menu bar (`Tests/ClaudeStatsTests`). UI-only changes are fine without.
- Update `README.md` for user-visible behaviour and `docs/DESIGN.md` for
  reasoning that a future contributor would otherwise have to re-derive.
- One change per pull request. CI must pass.

## Releases

Maintainers cut releases from `main` via the Release workflow — push a tag
`vX.Y.Z` or run it manually with a version. Signing and notarization happen in
CI with organisation-held credentials; contributors don't need any of that.
