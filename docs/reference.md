# DeskMate reference

Everything the [README](../README.md) does not have room for: build and run
details, the analysis pipeline, the privacy internals, the test harness, and
every tunable and environment variable.

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

**Analysis** (`DeskMateAnalyzer`) — runs only when you click *Analyze* in the dashboard. Captures from the last 7 days are clustered locally into sessions (same app/host, gaps under 5 minutes, sessions shorter than 60s dropped). Session digests then go to Claude in three passes: Haiku labels each session in batches of 12, Opus reads the labeled timeline and proposes procedures, and Opus writes an automation plan for each proposal that survives. Between the last two the Claude connector directory is refreshed — at most weekly — so a plan only names connectors that actually exist.

Two things keep a re-run cheap and quiet. Labels are cached in the database under a session id that is a stable hash of (start, bucket), so re-clustering doesn't pay Haiku twice for the same session. And a proposal matching a workflow you dismissed in the last 7 days is recorded as auto-dismissed rather than shown again.

**Dashboard** (`DeskMateDashboard`) — five tabs. *Today* shows where your time went, *Workflows* holds the procedures you kept, *Suggestions* lists what Claude proposed (keep or dismiss), *Team* joins a shared hub and shows which workflows you have shared to it, and *Settings* switches off anything the app does on its own. The views are built from Celadon (青瓷), the design system under `Sources/DeskMateDashboard/DesignSystem`; `DESKMATE_DESIGN_MODE=1` replaces the whole window with its component catalog, which is how you read the design docs without an Xcode preview canvas.

## Privacy

This tool sees everything on your screen, so the defaults are deliberately conservative:

- **Screenshots never leave the machine.** Only text digests — app name, URL host and paths, window titles, and a ~200 character redacted OCR snippet per session — are sent to the Claude API.
- **Analysis is manual** — except the nightly summary, if you enable it. The daemon never calls out to the network. Nothing is sent until you click *Analyze*, or until the scheduled summary runs (see Daily summary below), which sends a sample of screen text to Claude every night and writes the result to Google Drive.
- **Apps are excluded by bundle ID** — 1Password, Keychain Access, and the login window are skipped entirely (`Sources/DeskMateCore/Config.swift`).
- **URLs are excluded by host fragment** — anything containing `bank`, `chase.com`, `wellsfargo.com`, or `1password.com` is dropped before capture.
- **OCR text is redacted** before it's written to disk: emails, card numbers, SSNs, `password:`/`api_key:` lines, `sk-` keys, and long hex tokens.
- **Captures and screenshots are purged after 30 days**, checked once per day by the daemon.
- **Sharing to the team hub is per-workflow and deliberate.** Only a workflow's title, summary, trigger, SOP steps and automation plan leave the machine — never captures, screenshots or OCR text. `SharePayload` is the whole wire format, and the preview you approve is built from the same type the client uploads, so the two cannot drift. Before it sends, `SensitivityScan` flags emails, URLs, proper nouns, people and monetary amounts in that text: SOP steps are *written by the model after the fact*, so nothing in them ever passed through capture-time redaction. It flags and never removes — what is fine to share with your employer is your call, not a regex's.

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

Run it by hand any time with `./scripts/daily-summary.sh`: `--dir <folder>`
overrides the destination directory, `--out <file>` names the file outright,
`--no-narrative` skips the model call, and `--force` ignores the off switch.
`DESKMATE_SUMMARY_MODEL` picks the model for the prose (default
`claude-sonnet-5`). Output goes to `~/Library/Logs/deskmate-summary.log`.

The plist hard-codes an absolute path to `scripts/daily-summary.sh` and to the
log, so a copy of the repo somewhere else needs those two lines edited before
`launchctl load`.

If the Mac is asleep at 23:59, launchd runs the job on wake rather than skipping
the day, and the job notices it is late: past midday it summarises the current
day, before midday it summarises the day before. The file is named for the day
it describes, not the moment it ran.

## Newsletter audio

`newsletter_voice.py` reads a finished brief out of the same Drive folder and
speaks it into an MP3, so the morning read can happen on a commute instead of
at a desk. It is a standalone script — nothing in the Swift app calls it, and
it does not touch the capture database.

```sh
pip install openai
export OPENAI_API_KEY=sk-...
export BRIEF_DIR="$HOME/Library/CloudStorage/GoogleDrive-you@example.com/My Drive/top_of_your_mind"

python3 newsletter_voice.py --latest              # newest YYYY-MM-DD-brief.(html|md|txt)
python3 newsletter_voice.py brief.html            # a specific file
python3 newsletter_voice.py brief.html --highlights # first six substantial paragraphs
```

It writes `<BRIEF_DIR>/audio/newsletter-YYYY-MM-DD.mp3`, named for the date in
the *filename* of the brief rather than its mtime, so a re-run of an old brief
does not claim to be today's. Setting `BRIEF_DIR` is in practice required: the
built-in default is `~/Google Drive/My Drive/top_of_your_mind`, which is not
where current versions of Drive sync, and the script exits with the path it
looked in rather than guessing.

Note that this one is OpenAI, not Claude — `gpt-4o-mini-tts`, chosen because
`instructions` (the "warm, brisk morning-briefing host" steer) does not work on
`tts-1`. The text is cleaned of HTML and Markdown and split into chunks under
3500 characters, since the speech endpoint rejects input over 4096. Chunks are
concatenated with the leading ID3 tag stripped off every part but the first,
and the file is written aside as `.part` and renamed, so Drive never syncs a
half-written MP3.

## Layout

| Target | What's in it |
|---|---|
| `DeskMateCore` | `Config` (intervals, paths, exclusions), GRDB `Storage` + migrations, `Capture` / `Workflow` models, Vision OCR, redaction, daemon control, team account and hub client |
| `DeskMateDaemon` | capture loop, screenshot, idle detection, browser URL, permission check |
| `DeskMateAnalyzer` | session clustering, Anthropic Messages API client, Haiku labeling, Opus pattern detection, automation planning |
| `DeskMateDashboard` | SwiftUI app — Today, Workflows, Suggestions, Team, Settings — over the Celadon design system in `DesignSystem/` (tokens, primitives, components, catalog) |
| `DeskMateFixture` | test harness: fixture runs, comparator checks, sharing checks, hub round trips (see below) |
| `DeskMateSummary` | the nightly activity summary that the launchd job runs |
| `server/` | the team hub — FastAPI over Postgres, deployed separately ([its own README](server/README.md)) |
| `scripts/` | `daily-summary.sh` and the launchd plist that runs it |
| `newsletter_voice.py` | standalone: turns a finished brief into an MP3 (OpenAI TTS) |

## Test harness

`DeskMateFixture` is one binary with a handful of subcommands. Most are local
and free; the two that spend API credit say so.

With no subcommand it builds a fixture database from AgentNet trajectories —
`DeskMateFixture <derived-dir> <output.sqlite>` — running the real `OCR`,
`Redactor` and `Storage` at production settings, so a fixture is produced by
the same code the daemon runs. Nothing derived from a task instruction is
allowed into a row: the instruction is the answer the detector is meant to
reconstruct, and leaking it would make the test pass for the wrong reason.

| Command | What it does |
|---|---|
| `verify <db>` | reports what local clustering sees — no API call |
| `analyze <db> [days]` | runs the real pipeline against a fixture (**spends API credit**) |
| `score <derived-dir> <db>` | scores what was found against what was planted, via `WorkflowComparator` rather than text match |
| `excerpt <db> [limit]` | dumps the OCR text a run would actually send |
| `share-preview <db> [--json] [--emit]` | shows the exact `SharePayload` bytes for a workflow |
| `sharing-check` | exercises the sharing state machine and the soft-delete guarantee on a throwaway database |
| `cross-person` | what `WorkflowComparator` does when several people run "the same" procedure slightly differently |
| `sanitize-check` | the tools sanitiser, against a real leak and against entries it must not eat |
| `team enroll <code> <email> <name>` / `team status` / `team disconnect` | hub round trips against a real server |
| `capabilities` / `capabilities check` | print the bundled capability catalog, or check it against the live one |
| `connectors [db]` | force a refresh of the Claude connector directory (**network**) |

`DESKMATE_STORAGE_DIR` points these at a scratch directory. Use it — `analyze`
writes suggestions, and neither it nor the fixture builder belongs anywhere
near the database you actually collect into.

## Configuration

There is no config file yet — `settings.json` next to the database holds only
the daily-summary switch. Tunables live in `Sources/DeskMateCore/Config.swift`:

| Setting | Default |
|---|---|
| `captureIntervalSeconds` | 30 |
| `idleThresholdSeconds` | 120 |
| `retentionDays` | 30 |
| `dismissalWindowDays` | 7 — how long a dismissal suppresses a procedure before it is proposed again |
| `connectorRefreshDays` | 7 — how long the Claude connector directory cache stays fresh |
| `connectorDirectoryURL` | `https://claude.com/connectors` |
| `hubURL` | `https://deskmate-hub.vercel.app` |
| `screenshotMaxDimension` | 1920 |
| `jpegQuality` | 0.5 |
| `excludedBundleIDs` | 1Password, Keychain Access, login window |
| `excludedURLHostFragments` | `bank`, `chase.com`, `wellsfargo.com`, `1password.com` |

Analysis lookback (7 days), session gap (5 min), and labeling batch size (12) are currently constructor defaults in `AnalysisRunner`, `SessionClusterer`, and `LabelingService`.

Models are constants too: `claude-haiku-4-5` for labeling, `claude-opus-4-7`
for pattern detection and automation planning, `claude-sonnet-5` for the
nightly prose.

**`hubURL` does not resolve yet.** The Vercel project is still named
`local-observer-hub` and was not renamed with the rest of the rebrand, so the
Team tab fails with "a server with this host name can't be found" — which reads
like a network problem rather than a wrong constant. Until the project is
renamed, run against the old host with
`DESKMATE_HUB_URL=https://local-observer-hub.vercel.app`.

### Environment variables

| Variable | Effect |
|---|---|
| `ANTHROPIC_API_KEY` | Required for analysis and for the nightly prose. Capture works without it. Read at launch — export it before starting the dashboard. |
| `DESKMATE_STORAGE_DIR` | Moves the database, screenshots and settings somewhere else. What keeps test tooling out of the database you actually use. |
| `DESKMATE_DAEMON_PATH` | Where the dashboard looks for `DeskMateDaemon`, if you moved the binaries apart. |
| `DESKMATE_HUB_URL` | Overrides `Config.hubURL` for one run. |
| `DESKMATE_SUMMARY_DIR` | Overrides where the nightly summary is written, ahead of the Google Drive lookup. |
| `DESKMATE_SUMMARY_MODEL` | Model for the nightly prose. Defaults to `claude-sonnet-5`. |
| `DESKMATE_DESIGN_MODE` | `1` replaces the dashboard window with the Celadon component catalog. |
| `OPENAI_API_KEY`, `BRIEF_DIR` | `newsletter_voice.py` only — nothing in the Swift app reads either. |
