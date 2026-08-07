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

The app polls it every 120 seconds (with a 10-second timer tolerance so macOS can
coalesce the wakeup), and again whenever you open the menu — so the numbers are always
fresh the moment you look at them, wherever the poll cycle happens to be. The interval
is deliberately unhurried: quota percentages move slowly, the endpoint throttles more
readily than the numbers change, and on-demand fetching covers the moment freshness
actually matters. Nothing polls while the machine is asleep; the first poll after wake
catches up.

## Token handling

The app **only reads** the access token, and re-reads it from the keychain on every
poll. Claude Code owns the refresh cycle and writes the fresh token back to the same
keychain item, so this app stays current without ever touching the refresh token or
writing to your credentials.

That ownership is deliberate, not laziness. The token endpoint returns a new
`refresh_token` alongside each access token — refresh tokens **rotate** — so a second
client performing its own refresh would invalidate the one Claude Code holds and break
your actual login. There is no safe way to have two independent owners of one
credential.

### Keeping it alive without running Claude Code

Access tokens last roughly eight hours and are only renewed while Claude Code is
running, so an app left up overnight would otherwise wake to a dead token. Instead of
refreshing the token itself, the app asks the CLI to do it:

- When the stored expiry is **within 10 minutes**, or a request comes back **401**, it
  runs `claude auth status --json` in the background.
- That command touches no inference, so it costs **none of the quota this app
  reports on** — which rules out the obvious alternative of firing a throwaway prompt.
  It returns in about 0.2s.
- It then re-reads the keychain and only reports a renewal if the token **actually
  changed**, rather than trusting the exit code.

If the refresh token itself has expired, no automation can help — the menu then offers
**Sign In to Claude Code…**, which opens Terminal running `claude auth login`.

The CLI is located by absolute path (`~/.local/bin/claude`, Homebrew, `/usr/local/bin`),
because an app launched by Finder or launchd inherits a bare `PATH`.

## Surviving an outage

The last successful reading is written to
`~/Library/Application Support/ClaudeStats/state.json` and restored at launch, before
the first network call. Without it the app opens blank after every launch and shows
nothing at all when the network is down or the endpoint is throttling — which is
exactly when you are most likely to be looking at it.

Rather than a boolean "offline" flag, the readout **fades with age**, because age is
the more useful signal: a reading four minutes old during a brief blip is still worth
reading at full strength, while one from this morning is not.

| Age | Appearance |
|-----|------------|
| under 5 min | full strength |
| under 30 min | slightly dimmed |
| under 6 hours | dimmed, age shown (`3h`) |
| older | heavily dimmed, age shown (`2d`) |

Stale data keeps its colour grade and simply recedes — deliberately different from
**paused**, which goes flat grey. The two states mean different things: "couldn't
update" versus "told not to update".

## Rate limiting

The usage endpoint throttles, and it will do so long before you notice any problem
with your Claude usage itself — restarting the app repeatedly during development is
enough to trip it. A 429 is therefore treated as a normal state to sit in rather than
an error to shout about: the last known figures stay on screen, and the dropdown
explains when the next attempt is due.

Backoff doubles from the poll interval up to a 30-minute ceiling and resets on the
first success. The server has been observed sending `retry-after: 0`, which taken
literally would mean no backoff at all, so its hint is treated as a **floor** to
respect rather than a licence to retry immediately. The backoff binds manual refreshes
too — hammering a throttled endpoint only extends the throttle.

## Diagnostics

A menu bar app has nowhere to show a stack trace, so anything worth diagnosing is
appended to `~/Library/Logs/ClaudeStats.log`. It records state *transitions* — the
first success after a failure, HTTP errors, throttles, renewals — rather than a line
per poll, so the events that explain a problem aren't buried. It truncates at 256 KB.

## Pausing

**Pause for 12 Hours** (⌘P) stops polling; the menu bar keeps showing the last known
figures but greys the whole readout behind a `⏸`, since a live colour grade would imply
data that is no longer current. The pause survives quits and reboots, expires on its
own, and **Resume Polling** ends it early.

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
| `Sources/ClaudeStats/ClaudeCLI.swift` | Nudges the CLI to renew its own login |
| `Sources/ClaudeStats/Store.swift` | Last-reading persistence and the staleness ladder |
| `Sources/ClaudeStats/Log.swift` | Append-only diagnostics log |

`Presentation` is deliberately free of app state, so the exact strings the app draws
can be rendered to a PNG from a throwaway `main.swift` compiled against these sources
— which is how the colour scale above was checked in both appearances without
launching anything.
