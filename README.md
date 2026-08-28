# Local Observer

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
.build/release/ObserverDashboard
```

**4. Press Start**, top right. The dashboard spawns `ObserverDaemon` for you
and shows a red dot while it runs; **Stop** ends it.

**5. Grant permissions.** macOS will prompt on first capture. Whatever you miss,
the daemon reports at startup in
`~/Library/Application Support/LocalObserver/daemon.log`:

```
[observer] permissions:
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
If you move the binaries apart, point `OBSERVER_DAEMON_PATH` at the daemon.

## How it works

```
ObserverDaemon  ──►  ~/Library/Application Support/LocalObserver/
  every 30s            observer.sqlite      (captures, suggestions, workflows)
  screenshot           screenshots/*.jpg    (local only, purged after 30 days)
  + OCR + redact
                              │
                              ▼
ObserverDashboard  ──►  cluster into sessions  ──►  Claude API  ──►  suggestions
  (SwiftUI, manual)       (local, no network)      (text digests only)
```

**Capture loop** (`ObserverDaemon`) — every 30 seconds, if you're not idle, it grabs the frontmost app name, window title, browser URL (via AppleScript), and a screenshot. Vision framework OCRs the image locally, a regex pass redacts secrets, and the row lands in SQLite.

**Analysis** (`ObserverAnalyzer`) — runs only when you click *Analyze* in the dashboard. Captures from the last 7 days are clustered locally into sessions (same app/host, gaps under 5 minutes, sessions shorter than 60s dropped). Session digests go to Claude in two passes: Haiku labels each session in batches of 12, then Opus reads the labeled timeline and proposes workflows.

**Dashboard** (`ObserverDashboard`) — four tabs. *Today* shows where your time went, *Workflows* holds the procedures you kept, *Suggestions* lists what Claude proposed (keep or dismiss), *Team* joins a shared hub and shows which workflows you have shared to it.

## Privacy

This tool sees everything on your screen, so the defaults are deliberately conservative:

- **Screenshots never leave the machine.** Only text digests — app name, URL host and paths, window titles, and a ~200 character redacted OCR snippet per session — are sent to the Claude API.
- **Analysis is manual.** The daemon never calls out to the network. Nothing is sent until you click *Analyze*.
- **Apps are excluded by bundle ID** — 1Password, Keychain Access, and the login window are skipped entirely (`Sources/ObserverCore/Config.swift`).
- **URLs are excluded by host fragment** — anything containing `bank`, `chase.com`, `wellsfargo.com`, or `1password.com` is dropped before capture.
- **OCR text is redacted** before it's written to disk: emails, card numbers, SSNs, `password:`/`api_key:` lines, `sk-` keys, and long hex tokens.
- **Captures and screenshots are purged after 30 days**, checked once per day by the daemon.

Redaction is regex-based and best-effort — it is not a guarantee. If an app shows something you'd rather never be captured, add its bundle ID to `excludedBundleIDs`.

To wipe everything:

```sh
rm -rf ~/Library/Application\ Support/LocalObserver
```

## Layout

| Target | What's in it |
|---|---|
| `ObserverCore` | `Config` (intervals, paths, exclusions), GRDB `Storage` + migrations, `Capture` / `Workflow` models, Vision OCR, redaction, daemon control, team account and hub client |
| `ObserverDaemon` | capture loop, screenshot, idle detection, browser URL, permission check |
| `ObserverAnalyzer` | session clustering, Anthropic Messages API client, Haiku labeling, Opus pattern detection, automation planning |
| `ObserverDashboard` | SwiftUI app — Today, Workflows, Suggestions, Team |
| `ObserverFixture` | test harness: fixture runs, comparator checks, sharing checks, hub round trips |
| `server/` | the team hub — FastAPI over Postgres, deployed separately ([its own README](server/README.md)) |

## Configuration

There is no config file yet. Tunables live in `Sources/ObserverCore/Config.swift`:

| Setting | Default |
|---|---|
| `captureIntervalSeconds` | 30 |
| `idleThresholdSeconds` | 120 |
| `retentionDays` | 30 |
| `screenshotMaxDimension` | 1920 |
| `jpegQuality` | 0.5 |
| `excludedBundleIDs` | 1Password, Keychain Access, login window |
| `excludedURLHostFragments` | `bank`, `chase.com`, `wellsfargo.com`, `1password.com` |

Analysis lookback (7 days), session gap (5 min), and labeling batch size (12) are currently constructor defaults in `AnalysisRunner`, `SessionClusterer`, and `LabelingService`.