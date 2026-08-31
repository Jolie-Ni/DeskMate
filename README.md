# DeskMate

A macOS app that quietly watches how you actually work, then tells you which parts of it could be handed to an AI.

It runs a background daemon that samples your screen every 30 seconds, OCRs it on-device, and stores the result in a local SQLite database. When you ask for it, a dashboard clusters those samples into work sessions, sends *text digests only* to the Claude API, and surfaces suggestions like "you LinkedIn-search every prospect before a sales call — here's a workflow that does it for you."

Nothing is analyzed until you press the button. No screenshots ever leave your machine.

## Run

macOS 14 or later, a Swift 5.9+ toolchain (Xcode 15+ or Command Line Tools),
and an Anthropic API key — the key is for analysis only, capture works without
one.

**1. Build.** Both binaries have to land in the same directory, because the
dashboard looks for the daemon next to itself:

```sh
swift build -c release
```

**2. Set your API key.** The dashboard reads it from the environment *at
launch*, so it has to be exported in the same shell you start it from — setting
it afterwards does nothing until you relaunch. Put it in your shell profile if
you would rather not think about it again:

```sh
export ANTHROPIC_API_KEY=sk-ant-...
```

Launched from Finder the dashboard never sees a key, and *Analyze* will tell
you so. Capture and everything already collected still work fine.

**3. Open the dashboard.** That is the whole thing — there is no separate
daemon to run:

```sh
.build/release/DeskMateDashboard
```

**4. Press Start**, top right. The dashboard spawns `DeskMateDaemon` for you
and shows a red dot while it runs; **Stop** ends it.

**5. Grant permissions.** macOS will prompt on first capture. Whatever you miss,
the daemon reports at startup in
`~/Library/Application Support/DeskMate/daemon.log`:

```
[deskmate] permissions:
  Screen Recording: ✅
  Accessibility:    ❌
```

| Permission | Used for |
|---|---|
| Screen Recording | screenshots |
| Accessibility | frontmost window title |
| Automation | browser URL via AppleScript — prompted on first use |

Grant what is missing in **System Settings → Privacy & Security**, then Stop and
Start again. The grant attaches to the binary that asked for it, so it may need
redoing after a rebuild that moves the binary.

Then let it collect for a day or two before expecting suggestions — patterns
need repetition to be visible.

The daemon is deliberately not tied to the window's lifetime: closing the
dashboard leaves recording running, because quitting a window you opened to
read something should not silently stop collection. Stopping is an explicit act.
If you move the binaries apart, point `DESKMATE_DAEMON_PATH` at the daemon.

## How it works

```
DeskMateDaemon  ──►  ~/Library/Application Support/DeskMate/
  every 30s            deskmate.sqlite      (captures, suggestions, workflows)
  screenshot           screenshots/*.jpg    (local only, purged after 30 days)
  + OCR + redact
                              │
                              ▼
DeskMateDashboard  ──►  cluster into sessions  ──►  Claude API  ──►  suggestions
  (SwiftUI, manual)       (local, no network)      (text digests only)
```

**Capture loop** (`DeskMateDaemon`) — every 30 seconds, if you're not idle, it grabs the frontmost app name, window title, browser URL (via AppleScript), and a screenshot. Vision framework OCRs the image locally, a regex pass redacts secrets, and the row lands in SQLite.

**Analysis** (`DeskMateAnalyzer`) — runs only when you click *Analyze* in the dashboard. Captures from the last 7 days are clustered locally into sessions (same app/host, gaps under 5 minutes, sessions shorter than 60s dropped). Session digests go to Claude in two passes: Haiku labels each session in batches of 12, then Opus reads the labeled timeline and proposes workflows.

**Dashboard** (`DeskMateDashboard`) — four tabs. *Today* shows where your time went, *Workflows* holds the procedures you kept, *Suggestions* lists what Claude proposed (keep or dismiss), and *Settings* switches off anything the app does on its own. A fifth tab, *Team*, joins a shared hub and shows what you have shared to it; it is hidden behind `Config.sharingEnabled`, which is `false` — see [Team sharing](#team-sharing).

## Privacy

This tool sees everything on your screen, so the defaults are deliberately conservative:

- **Screenshots never leave the machine.** Only text digests — app name, URL host and paths, window titles, and a ~200 character redacted OCR snippet per session — are sent to the Claude API.
- **Analysis is manual** — except the nightly summary, if you enable it. The daemon never calls out to the network. Nothing is sent until you click *Analyze*, or until the scheduled summary runs (see Daily summary below), which sends a sample of screen text to Claude every night and writes the result to Google Drive.
- **Apps are excluded by bundle ID** — 1Password, Keychain Access, and the login window are skipped entirely (`Sources/DeskMateCore/Config.swift`).
- **URLs are excluded by host fragment** — anything containing `bank`, `chase.com`, `wellsfargo.com`, or `1password.com` is dropped before capture.
- **OCR text is redacted** before it's written to disk: emails, card numbers, SSNs, `password:`/`api_key:` lines, `sk-` keys, and long hex tokens.
- **Captures and screenshots are purged after 30 days**, checked once per day by the daemon.

Redaction is regex-based and best-effort — it is not a guarantee. If an app shows something you'd rather never be captured, add its bundle ID to `excludedBundleIDs`.

To wipe everything:

```sh
rm -rf ~/Library/Application\ Support/DeskMate
```

## Daily summary

An optional nightly job writes an activity file for a newsletter, a journal, or
anything else that wants context about the week.

```sh
swift build -c release
cp scripts/com.hconsult.deskmate.summary.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.hconsult.deskmate.summary.plist
```

It runs at 23:59 and writes
`<Google Drive>/My Drive/top_of_your_mind/activity/YYYY-MM-DD-activity.md`,
one file per day, each holding three windows: the day itself, the last 7 days
and the last 30 days. Every window gets an hours-and-apps breakdown computed
locally, plus a few paragraphs of prose written by Claude from the screen text
of that window.

**This sends data off the machine, on a schedule, without you pressing
anything.** A sample of OCR text goes to the Claude API each night, and the
resulting summary syncs to Google Drive, where it is as private as that Drive
folder is. The summaries name real projects, documents and people, because a
vague one would be useless. If that is not what you want, do not load the job —
nothing else in the app behaves this way.

The prose needs an API key, which launchd will not inherit from your shell:

```sh
printf 'ANTHROPIC_API_KEY=%s\n' "$ANTHROPIC_API_KEY" \
  > ~/Library/Application\ Support/DeskMate/summary.env
chmod 600 ~/Library/Application\ Support/DeskMate/summary.env
```

Without it the job still runs and still writes the file, minus the prose.

**Turning it off.** The *Settings* tab has a switch for it. That writes
`settings.json` next to the database, which the summary binary reads before it
does anything — a file rather than `UserDefaults`, because defaults are scoped
per executable and the dashboard and the summary are separate binaries. The
scheduled job still fires and exits without writing; `launchctl unload` removes
it entirely.

Run it by hand any time with `./scripts/daily-summary.sh`, override the
destination with `--dir`, skip the model call with `--no-narrative`, and ignore
the off switch with `--force`.
Output goes to `~/Library/Logs/deskmate-summary.log`.

If the Mac is asleep at 23:59, launchd runs the job on wake rather than skipping
the day, and the job notices it is late: past midday it summarises the current
day, before midday it summarises the day before. The file is named for the day
it describes, not the moment it ran.

## Layout

| Target | What's in it |
|---|---|
| `DeskMateCore` | `Config` (intervals, paths, exclusions), GRDB `Storage` + migrations, `Capture` / `Workflow` models, Vision OCR, redaction, daemon control, team account and hub client |
| `DeskMateDaemon` | capture loop, screenshot, idle detection, browser URL, permission check |
| `DeskMateAnalyzer` | session clustering, Anthropic Messages API client, Haiku labeling, Opus pattern detection, automation planning |
| `DeskMateDashboard` | SwiftUI app — Today, Workflows, Suggestions, Settings (+ Team, behind `Config.sharingEnabled`) |
| `DeskMateFixture` | test harness: fixture runs, comparator checks, sharing checks, hub round trips |
| `DeskMateSummary` | the nightly activity summary that the launchd job runs |
| `server/` | the team hub — FastAPI over Postgres, deployed separately ([its own README](server/README.md)) |

## Configuration

There is no config file yet. Tunables live in `Sources/DeskMateCore/Config.swift`:

| Setting | Default |
|---|---|
| `captureIntervalSeconds` | 30 |
| `idleThresholdSeconds` | 120 |
| `retentionDays` | 30 |
| `screenshotMaxDimension` | 1920 |
| `jpegQuality` | 0.5 |
| `excludedBundleIDs` | 1Password, Keychain Access, login window |
| `excludedURLHostFragments` | `bank`, `chase.com`, `wellsfargo.com`, `1password.com` |
| `sharingEnabled` | `false` — see below |

### Team sharing

`Config.sharingEnabled` is `false`. DeskMate is aimed at individuals while we
collect feedback; sharing only pays off selling into enterprises, so it is off
rather than half-working. With the flag false:

- the **Team** tab is not in the tab bar, so there is nowhere to enter an
  enrolment token
- workflow rows show no **Share** / **Retract** / **Retry** controls
- a suggestion offers plain **Save as workflow**, not **Save & share with team**
- `enroll`, `share` and `retract` refuse to run, so nothing reaches the hub even
  if a code path gets there

It is a flag rather than a deletion: `HubClient`, the sensitivity scan and the
share preview stay compiled, so turning it back on is one line. A machine that
enrolled earlier keeps its stored account — it just stops being offered.

Before flipping it to `true`, rename the Vercel project to `deskmate-hub`;
`Config.hubURL` does not resolve until you do. `DeskMateFixture`'s team
subcommands are deliberately *not* gated, so you can exercise the hub with
`DESKMATE_HUB_URL` while the product feature is still off.

Analysis lookback (7 days), session gap (5 min), and labeling batch size (12) are currently constructor defaults in `AnalysisRunner`, `SessionClusterer`, and `LabelingService`.