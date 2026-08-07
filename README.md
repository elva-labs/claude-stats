# Claude Stats

A macOS menu bar app that keeps your Claude usage percentages visible at all times —
the same numbers `/usage` shows inside Claude Code.

```
s 49% · w 6% · f 12%
```

| Marker | Limit |
|--------|-------|
| `S`    | Current 5-hour session |
| `W`    | Weekly, all models |
| `F`    | Weekly, Fable (per-model scoped limit) |

Markers are derived from the API response, so any additional scoped limit your plan
gains (Opus, Sonnet, Cowork, …) shows up automatically with its own initial.

## Reading it

The marker is set small and grey; the number is what your eye lands on. Its colour
runs a continuous scale — muted green when a quota is barely touched, through amber
and orange, to red as it runs out — rather than snapping between a few fixed states,
so a quota climbing through the afternoon reads as a gradual shift.

Two details make that scale hold up in practice. Saturation climbs with the number,
so a 3% quota is a calm grey-green that doesn't compete for attention while a 90% one
is fully vivid. And brightness is tuned per hue and per appearance, because hues
aren't equally legible against a background: amber has to sit much darker than red
before it reads on a light menu bar, and the reverse holds on a dark one.

If the server flags a limit as `critical`, it's shown red regardless of the number.

**When a quota is spent, the percentage is replaced by the wait:**

```
s 1h12m  ·  w 62%  ·  f 2d4h
```

"100%" tells you nothing you can act on — the only number left worth reading is how
long until it comes back. Healthy quotas keep their percentage, so the two states sit
side by side. The countdown re-renders every 30 seconds from cached data rather than
waiting on the network, and the moment a reset time passes the app refetches instead
of sitting out the rest of the poll interval.

The API exposes no documented "spent" flag, so this triggers on `percent >= 100`,
with a small set of plausible severity words (`exceeded`, `blocked`, `reached`,
`depleted`) as a fallback in case a limit is ever reported as blocked below 100%.

Clicking the item opens a dropdown with full names, a mini meter per quota, reset
countdowns, extra-usage credits (when enabled), a manual refresh, and a **Start at
Login** toggle. Clicking a row copies that quota's summary to the clipboard.

## Where the numbers come from

Claude Code authenticates with an OAuth token stored in the login keychain under the
service `Claude Code-credentials`. That token is accepted by:

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <access token>
anthropic-beta: oauth-2025-04-20
```

The response's `limits[]` array is the source of truth:

```json
{"kind": "session",        "group": "session", "percent": 49, "severity": "normal", "resets_at": "…"}
{"kind": "weekly_all",     "group": "weekly",  "percent": 6,  "severity": "normal", "resets_at": "…"}
{"kind": "weekly_scoped",  "group": "weekly",  "percent": 12, "scope": {"model": {"display_name": "Fable"}}}
```

The app polls it every 60 seconds (with a 10-second timer tolerance so macOS can
coalesce the wakeup), and again whenever you open the menu — so the numbers are always
fresh the moment you look at them, wherever the poll cycle happens to be. Nothing
polls while the machine is asleep; the first poll after wake catches up.

## Token handling

The app **only reads** the access token, and re-reads it from the keychain on every
poll. Claude Code owns the refresh cycle and writes the fresh token back to the same
keychain item, so this app stays current without ever touching the refresh token or
writing to your credentials.

On first launch macOS asks whether this app may read that keychain item — click
**Always Allow**. The permission is remembered against the app's code signature, so
rebuilding the app will ask once more.

If the token is ever rejected, the menu bar shows `⚠︎` next to the last known
percentages and the dropdown explains why.

## Build and install

```sh
./build.sh
```

That compiles a release binary, wraps it in `Claude Stats.app` (with `LSUIElement`
set, so no Dock icon), ad-hoc signs it, installs it to `/Applications`, and launches
it. Re-running the script replaces a running copy.

Requires macOS 14+ and the Swift toolchain that ships with Xcode.

## Layout

| File | Purpose |
|------|---------|
| `Sources/ClaudeStats/main.swift` | Status item, menu, polling loop |
| `Sources/ClaudeStats/UsageAPI.swift` | Endpoint client and response decoding |
| `Sources/ClaudeStats/Gauge.swift` | Limit → display model (labels, resets, severity) |
| `Sources/ClaudeStats/Grade.swift` | The colour scale and the mini meters |
| `Sources/ClaudeStats/Presentation.swift` | Menu bar title and dropdown row typography |
| `Sources/ClaudeStats/Keychain.swift` | Read-only access-token lookup |

`Presentation` is deliberately free of app state, so the exact strings the app draws
can be rendered to a PNG from a throwaway `main.swift` compiled against these sources
— which is how the colour scale above was checked in both appearances without
launching anything.
