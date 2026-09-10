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

**2. Set your API key.** The first launch asks for one and verifies it against
the Messages API before saving, so a mistyped key fails there rather than an
hour later at *Analyze*. It lands in `~/Library/Application Support/DeskMate/api-key`
at mode `0600`, and *Settings* can replace or remove it afterwards.

Skipping is fine. Capture never touches the network; only *Analyze* and the
nightly summary need a key.

A shell export still wins over the saved file, which keeps CLI and test runs
behaving as they always did:

```sh
export ANTHROPIC_API_KEY=sk-ant-...
```

That precedence is why *Settings* says so plainly when the environment supplies
a key — editing the saved one would otherwise look like it worked and change
nothing.

**Why a file and not the Keychain.** Keychain ACLs key off each binary's code
signature. A key written by the dashboard would make `DeskMateSummary` raise an
"allow access?" dialog when the 23:59 launchd job tried to read it, and nobody
is awake to answer. The file also sits beside `deskmate.sqlite`, which holds
OCR'd text from your screen — anything that can read the key can already read
worse.

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
DeskMateDashboard  ──►  cluster into sessions  ──►  model provider  ──►  suggestions
  (SwiftUI, manual)       (local, no network)      (text digests only)
                                                   Claude by default; see
                                                   providers.json
```

**Capture loop** (`DeskMateDaemon`) — every 30 seconds, if you're not idle, it grabs the frontmost app name, window title, browser URL (via AppleScript), and a screenshot. Vision framework OCRs the image locally, a regex pass redacts secrets, and the row lands in SQLite.

**Analysis** (`DeskMateAnalyzer`) — runs only when you click *Analyze* in the dashboard. Captures from the last 7 days are clustered locally into sessions (same app/host, gaps under 5 minutes, sessions shorter than 60s dropped). Session digests then go to Claude in three passes: Haiku labels each session in batches of 12, Opus reads the labeled timeline and proposes procedures, and Opus writes an automation plan for each proposal that survives. Between the last two the Claude connector directory is refreshed — at most weekly — so a plan only names connectors that actually exist.

Two things keep a re-run cheap and quiet. Labels are cached in the database under a session id that is a stable hash of (start, bucket), so re-clustering doesn't pay Haiku twice for the same session. And a proposal matching a workflow you dismissed in the last 7 days is recorded as auto-dismissed rather than shown again.

**Dashboard** (`DeskMateDashboard`) — four tabs. *Today* shows where your time went, *Workflows* holds the procedures you kept, *Suggestions* lists what Claude proposed (keep or dismiss), and *Settings* switches off anything the app does on its own. A fifth tab, *Team*, joins a shared hub and shows what you have shared to it; it is hidden behind `Config.sharingEnabled`, which is `false` — see [Team sharing](#team-sharing). The views are built from Celadon (青瓷), the design system under `Sources/DeskMateDashboard/DesignSystem`; `DESKMATE_DESIGN_MODE=1` replaces the whole window with its component catalog, which is how you read the design docs without an Xcode preview canvas.

## Privacy

This tool sees everything on your screen, so the defaults are deliberately conservative:

- **Screenshots never leave the machine.** Only text digests — app name, URL host and paths, window titles, and a ~200 character redacted OCR snippet per session — are sent to the Claude API.
- **Analysis is manual** — except the nightly summary, if you enable it. The daemon never calls out to the network. Nothing is sent until you click *Analyze*, or until the scheduled summary runs (see Daily summary below), which sends a sample of screen text to Claude every night and writes the result to Google Drive.
- **Apps are excluded by bundle ID** — 1Password, Keychain Access, and the login window are skipped entirely (`Sources/DeskMateCore/Config.swift`).
- **URLs are excluded by host fragment** — anything containing `bank`, `chase.com`, `wellsfargo.com`, or `1password.com` is dropped before capture.
- **OCR text is redacted** before it's written to disk: emails, card numbers, SSNs, `password:`/`api_key:` lines, `sk-` keys, and long hex tokens.
- **Captures and screenshots are purged after 30 days**, checked once per day by the daemon.
- **Sharing to the team hub is off entirely** (`Config.sharingEnabled` is `false`), so the rest of this bullet describes a path the shipped app cannot reach. When enabled, sharing is per-workflow and deliberate: only a workflow's title, summary, trigger, SOP steps and automation plan leave the machine — never captures, screenshots or OCR text. `SharePayload` is the whole wire format, and the preview you approve is built from the same type the client uploads, so the two cannot drift. Before it sends, `SensitivityScan` flags emails, URLs, proper nouns, people and monetary amounts in that text: SOP steps are *written by the model after the fact*, so nothing in them ever passed through capture-time redaction. It flags and never removes — what is fine to share with your employer is your call, not a regex's.

Redaction is regex-based and best-effort — it is not a guarantee. If an app shows something you'd rather never be captured, add its bundle ID to `excludedBundleIDs`.

To wipe everything:

```sh
rm -rf ~/Library/Application\ Support/DeskMate
```

## Daily summary

An optional nightly job writes an activity file for a newsletter, a journal, or
anything else that wants context about the week.

**Settings → Daily activity summary → Install** is the way in. It writes
`~/Library/LaunchAgents/com.hconsult.deskmate.summary.plist` pointing at the
`DeskMateSummary` binary sitting beside the app you clicked it in, then
bootstraps it into your GUI domain so it is live without a logout. *Remove*
boots it out and deletes the plist.

The plist is generated rather than checked in. A checked-in one has to name an
absolute path, and that path is only ever correct on the machine of whoever
wrote it — the one this repo used to carry pointed into its author's home
directory, which made the feature unreachable for everybody else. An app
installed from the DMG has no source checkout to point at at all.

The job runs the binary directly with no shell in between. The only thing the
old `daily-summary.sh` wrapper did that mattered was find an API key in an
environment launchd does not provide, and `APIKeyStore` now answers that for
every binary without an environment at all. The script is still there for
running a summary by hand.

Settings also notices a plist left behind by a copy of DeskMate that has since
been moved or deleted — the failure where the job is "installed" and silently
does nothing every night — and offers to repair it.

`DeskMateFixture summaryjob-check` exercises the whole cycle against a throwaway
label, so it never touches the job you actually have installed.

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

The prose needs an API key, which launchd will not inherit from your shell. A
key saved in the app is enough — `DeskMateSummary` reads the same
`api-key` file the dashboard writes. `summary.env` still works and still wins,
for anyone who set it up before the app could hold a key:

```sh
printf 'ANTHROPIC_API_KEY=%s\n' "$ANTHROPIC_API_KEY" \
  > ~/Library/Application\ Support/DeskMate/summary.env
chmod 600 ~/Library/Application\ Support/DeskMate/summary.env
```

With neither, the job still runs and still writes the file, minus the prose.

**Turning it off.** The *Settings* tab has a switch for it. That writes
`settings.json` next to the database, which the summary binary reads before it
does anything — a file rather than `UserDefaults`, because defaults are scoped
per executable and the dashboard and the summary are separate binaries. The
scheduled job still fires and exits without writing; `launchctl unload` removes
it entirely.

Run it by hand any time with `./scripts/daily-summary.sh`: `--dir <folder>`
overrides the destination directory, `--out <file>` names the file outright,
`--no-narrative` skips the model call, and `--force` ignores the off switch.
`DESKMATE_MODEL_NARRATION` picks the model for the prose (default
`claude-sonnet-5`; the older `DESKMATE_SUMMARY_MODEL` still works). Output goes to `~/Library/Logs/deskmate-summary.log`.

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
| `DeskMateCore` | `Config` (intervals, paths, exclusions), GRDB `Storage` + migrations, `Capture` / `Workflow` models, Vision OCR, redaction, daemon control, `APIKeyStore`, `SummaryJob`, team account and hub client |
| `DeskMateDaemon` | capture loop, screenshot, idle detection, browser URL, permission check |
| `DeskMateAnalyzer` | session clustering, Anthropic Messages API client, Haiku labeling, Opus pattern detection, automation planning |
| `DeskMateDashboard` | SwiftUI app — Today, Workflows, Suggestions, Settings (+ Team, behind `Config.sharingEnabled`) — over the Celadon design system in `DesignSystem/` (tokens, primitives, components, catalog) |
| `DeskMateFixture` | test harness: fixture runs, comparator checks, sharing checks, hub round trips (see below) |
| `DeskMateSummary` | the nightly activity summary that the launchd job runs |
| `server/` | the team hub — FastAPI over Postgres, deployed separately ([its own README](server/README.md)) |
| `scripts/` | `package.sh` (see [Packaging](#packaging)) and `daily-summary.sh`, the latter kept only for running a summary by hand — Settings → Install is what schedules one |
| `packaging/` | `Info.plist`, entitlements, `make-icon.swift` and the generated `.icns`, and the Homebrew cask |
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
| `sweep <derived-dir> <fixture> <spec.json> [--repeats N] [--go]` | runs the pipeline under several provider configurations and puts recall, tokens and wall clock side by side. Prints the plan and stops unless `--go` (**spends real credit, once per configuration per repeat**) |
| `excerpt <db> [limit]` | dumps the OCR text a run would actually send |
| `share-preview <db> [--json] [--emit]` | shows the exact `SharePayload` bytes for a workflow |
| `sharing-check` | exercises the sharing state machine and the soft-delete guarantee on a throwaway database |
| `cross-person` | what `WorkflowComparator` does when several people run "the same" procedure slightly differently |
| `sanitize-check` | the tools sanitiser, against a real leak and against entries it must not eat |
| `summaryjob-check` | writes, bootstraps, reads back and boots out the nightly launchd agent, under a throwaway label so the real job is untouched |
| `keystore-check` | the API key store: round trip, whitespace trimming, and that the file is `0600` and stays `0600`. Refuses to run without `DESKMATE_STORAGE_DIR`, since it writes and deletes the real key file |
| `models-check` | role → model resolution: defaults, the `DESKMATE_MODEL_*` overrides, and that the legacy `DESKMATE_SUMMARY_MODEL` name still works. Resolves names only — no API call |
| `provider-check` | encodes the request each call site builds, for both providers, and asserts the JSON — the Anthropic bodies against what was sent before `LLMProvider` existed. Also covers capability guards, provider selection, and that schema keys survive snake_case conversion. No API call |
| `provider-verify` | resolves the configured provider, prints its per-role models and capabilities, checks the credentials, and confirms the endpoint actually serves each role's model (**network**, no tokens spent) |
| `provider-smoke` | one small structured call per request shape, through the whole stack — schema accepted, effort tolerated, answer decoded (**spends a few cents**) |
| `json-check` | structured-output recovery: the extraction scan, and that `completeParsed` reaches for it only after a decode fails. Runs against a stub provider, so no API call |
| `metering-check` | that `MeteredProvider` counts calls, tokens and time per model, including under the concurrency the planning stage creates. Runs against a stub, so no API call |
| `stream-check` | SSE reassembly for both providers, driven by canned events: envelope edge cases, fragment concatenation, usage extraction, and the traps — thinking-delta contamination, a mid-stream error after a 200, unknown event types, and OpenAI's empty-choices usage chunk. No API call |
| `config-check` | `providers.json`: parsing, patching a built-in, defining a custom endpoint, the refusals, and that the environment outranks the file. Also the migration promise — no config file behaves exactly as before. Refuses to run without `DESKMATE_STORAGE_DIR`, since it writes and deletes real config and key files |
| `team enroll <code> <email> <name>` / `team status` / `team disconnect` | hub round trips against a real server |
| `capabilities` / `capabilities check` | print the bundled capability catalog, or check it against the live one |
| `connectors [db]` | force a refresh of the Claude connector directory (**network**) |

`DESKMATE_STORAGE_DIR` points these at a scratch directory. Use it — `analyze`
writes suggestions, and neither it nor the fixture builder belongs anywhere
near the database you actually collect into.

## Packaging

`./scripts/package.sh` builds `dist/DeskMate.app` and wraps it in
`dist/DeskMate-<version>.dmg`. Version comes from the latest git tag,
`CFBundleVersion` from the commit count.

All three executables — dashboard, daemon and summary — go into
`Contents/MacOS/` together. That is not tidiness; `DaemonControl` finds the
recorder as a *sibling* of whoever is asking, so moving the daemon into a
`Helpers/` folder would break Start. SwiftPM resource bundles go into
`Contents/Resources/`, where `Bundle.module` looks first.

Builds are universal (arm64 + x86_64) when full Xcode is installed, because
SwiftPM's multi-arch path runs through xcbuild, which the Command Line Tools do
not ship. With CLT only the script builds native and says so — CI has Xcode, and
the DMG that reaches users comes from there; a local one is for testing the
packaging.

`packaging/make-icon.swift` draws the icon from code against the Celadon
palette, so the `.icns` cannot drift from `DSTheme`. Re-run it after a palette
change:

```sh
swift packaging/make-icon.swift packaging/DeskMate.icns
```

### Signing

With no environment set the script ad-hoc signs. That ships something real
today, and it is what CI produces until an Apple Developer membership exists:

```sh
./scripts/package.sh
```

With a Developer ID certificate it signs properly, applies the hardened
runtime, notarizes and staples — same script, two variables:

```sh
xcrun notarytool store-credentials deskmate \
  --apple-id you@example.com --team-id TEAMID --password xxxx-xxxx-xxxx-xxxx

DESKMATE_SIGN_ID="Developer ID Application: Name (TEAMID)" \
DESKMATE_NOTARY_PROFILE=deskmate \
./scripts/package.sh
```

`packaging/DeskMate.entitlements` carries
`com.apple.security.automation.apple-events`. The hardened runtime blocks Apple
events outright without it, which would silently kill browser URL capture in
every notarized build while leaving ad-hoc builds working — the worst kind of
bug to find after release.

Signing runs inside out: nested bundles, then each executable, then the app.
Signing the app first and its contents second invalidates the outer signature,
and `codesign` does not say so. Only bundles carrying an `Info.plist` are signed
— SwiftPM emits resource-only bundles as a flat directory, which `codesign`
rejects as "bundle format unrecognized"; those are sealed by the app's own
resource envelope instead.

### What users see

Nothing. A notarized, stapled build opens on a double-click — no dialog, no
System Settings trip, and it works offline because the ticket is embedded rather
than fetched. `spctl -a -t exec DeskMate.app` reports `accepted,
source=Notarized Developer ID`, and the same holds for the DMG.

Homebrew still quarantines every download (`quarantine: true` is the default in
its installer, and Homebrew 6 removed the `--no-quarantine` flag), but that is
harmless now: Gatekeeper checks the stapled ticket, finds it valid, and lets the
app through.

An *unsigned* build still shows *"DeskMate is damaged and can't be opened"* —
Gatekeeper's wording for unsigned, not a corrupt file. That is what
`./scripts/package.sh` with no signing environment produces, and it is for
testing the packaging, not for shipping.

`packaging/homebrew/deskmate.rb` is the cask; it belongs in
`Jolie-Ni/homebrew-tap/Casks/`, and lives here so the version and checksum are
updated by the same commit as the build that produced them.

Worth knowing: TCC grants are keyed to a signature. Under the old ad-hoc builds
they were keyed to the binary's cdhash, so **Screen Recording had to be
re-granted after every update**. A Developer ID signature is stable across
versions, so the grant now survives an upgrade.

### Notarization is slow the first time

Apple holds a submission for in-depth analysis when it has not seen the app
before. The first DeskMate submission took **3.5 hours**; Apple's own guidance
is that the system learns to recognise an app and later submissions get faster.
There is nothing to fix and nothing to retry while it waits — a signing or
entitlement problem comes back `Invalid` within minutes, with a log naming it.
Resubmitting only queues another unfamiliar binary behind the first.

`notarize()` in `package.sh` therefore submits and polls separately rather than
using `notarytool submit --wait`, which abandons the run the moment one poll
fails. A few seconds of dropped wifi once killed a build *after* Apple had
accepted it, leaving the ticket unstapled and an hour of queue wasted. Failed
polls and failed staples are both retried; only a real `Invalid` verdict stops
the build.

`.github/workflows/release.yml` runs the same script on a `v*` tag and attaches
the DMG to the release. It notarizes only when the signing secrets are present,
so it works unchanged before and after enrolment.

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
| `sharingEnabled` | `false` — see [Team sharing](#team-sharing) |
| `hubURL` | `https://deskmate-hub.vercel.app` (unused while sharing is off) |
| `screenshotMaxDimension` | 1920 |
| `jpegQuality` | 0.5 |
| `excludedBundleIDs` | 1Password, Keychain Access, login window |
| `excludedURLHostFragments` | `bank`, `chase.com`, `wellsfargo.com`, `1password.com` |

Analysis lookback (7 days), session gap (5 min), and labeling batch size (12) are currently constructor defaults in `AnalysisRunner`, `SessionClusterer`, and `LabelingService`.

Models are chosen by *role*, not named at the call site. `ModelRole` in
`Sources/DeskMateAnalyzer/ModelRole.swift` defines three — `labeling` (cheap,
high volume), `reasoning` (pattern detection and automation planning), and
`narration` (the nightly prose).

Which model does each job belongs to the **provider**, not to the role: "the
cheap fast one" is a different string at every endpoint. Switching provider
therefore switches all three models, which is the only behaviour that does not
silently 404.

| Role | Variable | Anthropic | OpenAI |
|---|---|---|---|
| `labeling` | `DESKMATE_MODEL_LABELING` | `claude-haiku-4-5` | `gpt-5-mini` |
| `reasoning` | `DESKMATE_MODEL_REASONING` | `claude-opus-4-7` | `gpt-5` |
| `narration` | `DESKMATE_MODEL_NARRATION` (or `DESKMATE_SUMMARY_MODEL`) | `claude-sonnet-5` | `gpt-4.1` |

An override names a model, not a vendor, so it keeps applying whichever provider
is selected. Empty reads as unset.

### The provider layer

Nothing in the pipeline talks to Anthropic directly. `LabelingService`,
`PatternDetector`, `AutomationPlanner` and `Narrator` each hold an
`any LLMProvider` and build an `LLMRequest` — one system prompt, one user
message, and three hints: a JSON schema the answer must match, whether the
system prompt is worth caching, and how hard to think. There is no multi-turn
state, no tool loop and no image anywhere in the app, which is what keeps the
neutral request down to four fields.

The hints are hints. `ModelCapabilities` says what a given model can actually
do, and `AnthropicClient` consults it before spending a parameter — Haiku 4.5
rejects `output_config.effort` outright, so pointing the `reasoning` role at it
drops the hint instead of failing every analysis.

`completeParsed` is the one choke point every structured call passes through,
and the only place that knows a reply was supposed to be JSON. It decodes once;
if that fails it retries against `JSONExtraction.firstJSONValue`, which finds
the first complete JSON value in a reply that also contains something else — a
``` fence, a sentence of preamble, commentary afterwards. The happy path is
untouched, since both providers constrain generation to the schema and the
first decode succeeds.

That scan is balanced rather than first-brace-to-last-brace, because the cheap
version is wrong exactly where it matters: a model that answers and then keeps
talking, where the last `}` belongs to the commentary. String literals are
tracked so a brace inside a value — and OCR'd screen text is full of them —
does not shift the depth.

It is deliberately *not* a repair loop. Nothing asks a model to try again; that
is a separate cost and is not needed while both providers constrain output
natively. An endpoint that cannot — an open-weights server without guided
decoding — is where that decision gets revisited, and `structuredOutput` is the
flag that would drive it.

### Providers

Two conformers. `AnthropicClient` speaks the Messages API and is the default.
`OpenAICompatibleClient` speaks chat-completions and is configured by a
`ProviderProfile`: base URL, auth style, one model per role, and a capability
declaration. Adding a vendor is a profile, not a class — the wire format is
genuinely the same, and what differs is exactly what a profile carries.

That is also the seam for an open-weights model deployed in a customer's own
VPC. vLLM and TGI both expose this API, so such a deployment differs from OpenAI
only in base URL, auth and capabilities. A profile is deliberately plain data
with no closed enum of known vendors, because those endpoints cannot be
enumerated — their hostnames and model ids are internal to the customer.
`AuthStyle.none` exists for the same reason: an endpoint reachable only from
inside a private network is authenticated by the network, so the absence of a
key there is correct rather than a misconfiguration. mTLS and SigV4 are not
implemented yet; they need a URLSession delegate and a request signer.

Both clients keep their translation (`messagesRequest(for:)` /
`chatRequest(for:)`) separate from `complete`, so `provider-check` can assert
the wire format without spending a call.

**Requests stream.** Not for incremental output — no call site wants tokens as
they arrive, since three need a whole JSON document and one needs a whole
paragraph. It is a reliability property. A non-streamed request sends no bytes
at all until the answer is finished, so a model thinking for six minutes is
indistinguishable from a dead connection, and something in the middle usually
decides it is the latter. Two GPT-5 runs died that way before this existed.

`complete` accumulates the stream and returns the same `LLMResponse`, so nothing
above the provider knows. `ModelCapabilities.streaming` lets a minimal
self-hosted endpoint opt out, and both clients keep the non-streaming path for
that case.

The two vocabularies differ enough to be worth naming. Anthropic sends typed
events, of which four matter — and `thinking_delta` arrives on the same
`content_block_delta` event as `text_delta`, so folding it in would splice
reasoning into the answer. An `error` event can also arrive *after* a 200.
OpenAI sends one chunk shape, but its final usage chunk has an **empty**
`choices` array, so indexing `choices[0]` unconditionally crashes on the one
chunk carrying the token counts; it also needs `stream_options.include_usage`,
without which a streamed response reports no usage at all and every cost figure
would silently be zero.

Because streaming keeps bytes moving, `timeoutIntervalForRequest` is a real idle
timeout again — 300s, with a 1800s resource ceiling for a long analysis.

### Comparing providers

Model-agnostic means output quality now varies with configuration, and the only
honest way to say which models clear the bar is to measure. `sweep` runs the
real pipeline against one fixture under several configurations and reports what
each recovered, spent, and took.

```json
[
  { "label": "claude",         "provider": "anthropic" },
  { "label": "gpt-5",          "provider": "openai" },
  { "label": "cheap reasoner", "provider": "openai",
    "models": { "reasoning": "gpt-5-mini" } }
]
```

Each configuration gets its own copy of the fixture, because `analyze` writes
suggestions and caches labels into the database it reads — sharing one file
would let the first configuration's cached labels serve the second, which is
exactly what is under comparison.

Every configuration is resolved before any of them runs, so a missing key is
found for free rather than after three paid runs. A `DESKMATE_MODEL_*` variable
set in the shell is refused outright: it outranks every spec, which would
quietly make all configurations identical and the comparison a table of ties.

`--repeats N` runs each configuration N times and adds a per-configuration
spread. The models are non-deterministic, and a configuration that recovers 4
then 1 is not a 2.5-recall configuration — it is an unreliable one, which a
single run cannot show.

Cost is reported in tokens rather than money, with cache reads kept separate
since they are billed at a fraction of the input rate. A price table would have
to track several vendors' pricing pages and would be wrong the week one of them
changed; these numbers are exactly what a current price list needs.

### Configuring a provider

`providers.json`, in the storage directory beside the database. A file rather
than the environment because the environment does not reach the people who need
it: a double-clicked `.app` inherits launchd's environment, not a shell's, so
every `DESKMATE_*` variable is invisible to a packaged install — the same reason
the API key stopped being environment-only. The nightly launchd job has the same
problem.

A file rather than a settings screen, for now, because the configuration that
matters most is deployed rather than typed. An enterprise pointing fifty
machines at a model in its own VPC ships this file; it does not ask fifty people
to key in an internal hostname.

```json
{
  "selected": "acme-vpc",
  "providers": {
    "anthropic": {
      "models": { "reasoning": "claude-opus-5" }
    },
    "acme-vpc": {
      "displayName": "Acme internal vLLM",
      "baseURL": "https://llm.internal.acme.corp/v1",
      "auth": "none",
      "models": {
        "labeling":  "Qwen3-8B-Instruct",
        "reasoning": "Qwen3-72B-Instruct",
        "narration": "Qwen3-72B-Instruct"
      },
      "capabilities": { "reasoningEffort": false, "contextTokens": 32768 }
    }
  }
}
```

An entry whose id matches a built-in (`anthropic`, `openai`) **patches** it —
name only what you want to change, and a partial `models` map leaves the roles
it does not mention alone. Any other id **defines** a provider, must give a
`baseURL` and all three models, and is assumed to speak the OpenAI
chat-completions API. `auth` is `bearer` (default), `none`, or `header` with
`authHeader` naming the header.

Nothing secret goes here. Keys stay in their own `0600` files — `api-key` for
Anthropic (unchanged, so existing installs are untouched) and
`api-key-<provider>` for everything else — so `providers.json` is safe to diff,
log, or paste into a bug report.

A missing file means defaults. A **malformed** file is a hard error rather than
a shrug: someone edited it meaning to change something, and quietly carrying on
with the previous provider would spend the wrong money against the wrong key
while looking like it worked. The same goes for a provider that is selected but
undescribed, or described without a `baseURL` or without models.

**Precedence** is environment → `providers.json` → built-in defaults. The
environment stays on top because it is the escape hatch for a run that should
not disturb the machine's configuration — `DESKMATE_PROVIDER=openai
DeskMateFixture analyze …` must not mean editing a file the dashboard also
reads.

| Variable | Effect |
|---|---|
| `DESKMATE_PROVIDER` | Overrides `selected`. Trimmed, case-insensitive. |
| `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` | Override that provider's saved key. A custom provider uses `DESKMATE_API_KEY_<ID>`, e.g. `DESKMATE_API_KEY_ACME_VPC`. |
| `DESKMATE_OPENAI_BASE_URL` | Points the built-in `openai` profile at another endpoint. |

`DeskMateFixture provider-verify` resolves the configured provider, prints the
model and capabilities for each role, checks the credentials, and confirms the
endpoint serves each role's model. It costs no tokens — run it after configuring
a provider rather than discovering a bad key an hour into an analysis.

The model check is alias-aware. A listing returns canonical ids while an alias
is a valid thing to send: `claude-haiku-4-5` is absent from Anthropic's list but
generates fine, because the list carries `claude-haiku-4-5-20251001`. A served
id therefore counts when the remainder after the configured name is entirely
digits — narrow on purpose, since accepting any suffix would let `gpt-5` match a
served `gpt-5-mini` and pass a model the endpoint does not have.

`DeskMateFixture provider-smoke` goes further and issues real requests: one per
request shape, so both the schema-only translation and the schema-plus-effort
one are exercised. It **spends a few cents**, and it is the only check that
proves structured output actually works against a given endpoint — a `GET`
cannot. Worth running once whenever a new provider is configured.

### Team sharing

`Config.sharingEnabled` is `false`, so nothing in this section is reachable from
the shipped app. DeskMate targets individuals while feedback is being collected;
sharing only pays off selling into enterprises, and its hub host does not
resolve since the rebrand, so turning it off beat leaving it half-working.

With the flag false the *Team* tab is absent from the tab bar, workflow rows
show no Share / Retract / Retry controls, a suggestion offers plain "Save as
workflow" rather than "Save & share with team", and `enroll` / `share` /
`retract` refuse to run even if a code path reaches them. `DashboardSection.visible`
is the single source of which tabs exist.

It is a flag rather than a deletion: `HubClient`, `SensitivityScan` and the
share preview all stay compiled, so re-enabling is one line. `DeskMateFixture`'s
`team` subcommands stay ungated on purpose — they exist to exercise the hub
independently of what the product exposes.

**If you do re-enable it, `hubURL` does not resolve.** The Vercel project is
still named `local-observer-hub` and was not renamed with the rest of the
rebrand, so the Team tab fails with "a server with this host name can't be
found" — which reads like a network problem rather than a wrong constant. Point
a run at the old host with
`DESKMATE_HUB_URL=https://local-observer-hub.vercel.app`, or rename the project.

### Environment variables

| Variable | Effect |
|---|---|
| `ANTHROPIC_API_KEY` | Analysis and the nightly prose. Capture works without it. Takes precedence over the key saved in the app; unset or empty falls through to `~/Library/Application Support/DeskMate/api-key`. |
| `DESKMATE_STORAGE_DIR` | Moves the database, screenshots and settings somewhere else. What keeps test tooling out of the database you actually use. |
| `DESKMATE_DAEMON_PATH` | Where the dashboard looks for `DeskMateDaemon`, if you moved the binaries apart. |
| `DESKMATE_HUB_URL` | Overrides `Config.hubURL` for one run. |
| `DESKMATE_SUMMARY_DIR` | Overrides where the nightly summary is written, ahead of the Google Drive lookup. |
| `DESKMATE_MODEL_LABELING`, `DESKMATE_MODEL_REASONING`, `DESKMATE_MODEL_NARRATION` | Model per role. See the role table above for defaults. |
| `DESKMATE_SUMMARY_MODEL` | Older name for `DESKMATE_MODEL_NARRATION`, still honoured. Model for the nightly prose. Defaults to `claude-sonnet-5`. |
| `DESKMATE_PROVIDER` | Which provider to use. Overrides `selected` in `providers.json`. Defaults to `anthropic`. |
| `OPENAI_API_KEY` | Analysis and the nightly prose when the provider is `openai`. Takes precedence over `api-key-openai`. |
| `DESKMATE_API_KEY_<ID>` | The same, for a provider defined in `providers.json`. |
| `DESKMATE_OPENAI_BASE_URL` | Points the built-in `openai` profile at a different endpoint. |
| `DESKMATE_DESIGN_MODE` | `1` replaces the dashboard window with the Celadon component catalog. |
| `BRIEF_DIR` | `newsletter_voice.py` only — nothing in the Swift app reads it. |
