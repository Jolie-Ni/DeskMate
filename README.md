# Deskmate

**A forward deployed engineer, running on your laptop.**

Deskmate watches how you actually work for a week, then tells you which parts should be a machine's job.

<!-- Add docs/dashboard.png and uncomment. Left commented out so the README does
     not render a broken image in the meantime.
![Deskmate dashboard](docs/dashboard.png)
-->
<img width="1185" height="778" alt="image" src="https://github.com/user-attachments/assets/943121b4-e8e2-4468-a07a-8e36eddd19dd" />

<img width="1181" height="805" alt="image" src="https://github.com/user-attachments/assets/39611f6e-b543-42c1-b14f-8b2e4cbf2473" />

<img width="895" height="600" alt="image" src="https://github.com/user-attachments/assets/022b3958-f8c4-469d-99b5-3c57c8fbca4d" />



---

## Why this exists

I spent months as a forward deployed engineer, sitting inside companies and building AI into their workflows. The builds worked. Adoption still failed.

It did not fail because the models were not good enough. It failed because nobody in the building could answer a simple question: **which twenty minutes of your day should a machine be doing?** The executive could not say. The people doing the work could not say, because the work was invisible even to them. So we automated whatever was easiest to describe in a meeting, and then nobody counted whether it got used.

Deskmate is the tool I kept wishing existed. It answers the question from evidence instead of from a workshop.

---

## Try it out

Deskmate is an open-source native macOS app that lives locally on your own laptop. **You own your own data**. Nothing leaves your laptop without your permission.

**With Homebrew:**

```bash
brew install --cask jolie-ni/tap/deskmate
```

**Or download the app**: grab `DeskMate.dmg` from [Releases](https://github.com/Jolie-Ni/DeskMate/releases), open it, and drag DeskMate to Applications.

Builds are signed with a Developer ID certificate and notarized by Apple, with the ticket stapled into both the app and the disk image — so it opens on a double-click, offline, with no security dialog to dismiss.

On first launch DeskMate asks for your Anthropic API key and checks it against the API before saving. You can skip it — capture never touches the network and works with no key at all — and add one later in Settings. Anthropic is only the default; see [Choosing your model](#choosing-your-model) to point it somewhere else.

Then press **Start**, top right. That spawns the capture daemon; **Stop** ends it. The same two controls sit under the eye in the menu bar, so you can start and stop from whatever app you are in: the eye is filled while the recorder is capturing, outlined while it is running but you are idle, and struck through when nothing is recording. Closing the window leaves DeskMate in the menu bar and does not stop recording — stopping is meant to be a deliberate act.

Requires **macOS 14 or later**. macOS prompts for Screen Recording on first capture, and for Accessibility if you want window titles. Grant them in System Settings → Privacy & Security, then Stop and Start again. The recorder asks under its own name, `DeskMateDaemon`, because it is a separate process from the window you are looking at.

**Building from source** needs a **Swift 5.9+ toolchain** (Xcode 15+ or the Command Line Tools):

```bash
git clone https://github.com/Jolie-Ni/DeskMate
cd DeskMate
swift build -c release
.build/release/DeskMateDashboard      # or ./scripts/package.sh to build the DMG
```

Let it run for three or four working days before you look at the dashboard. The detector will not propose a procedure it has only seen on one day, so fewer than two days of data produces nothing at all.

---

## Choosing your model

Two separate choices, and it is worth knowing they are separate.

**Which model reads your week.** Anthropic by default. Nothing to configure if that is what you want.

**Which platform the suggestions are written for.** Claude by default, and it follows the first choice unless you say otherwise. This is what decides whether a suggestion says "enable the Gmail connector in Claude" or "build this as a ChatGPT workspace agent" — the two platforms can do genuinely different things, so a plan written for the wrong one wastes your time.

Both live in one file, `providers.json`, next to your database at `~/Library/Application Support/DeskMate/`. There is no such file until you make one, and no file means the defaults above.

### Setting up with an OpenAI key

Two files, four commands, all in `~/Library/Application Support/DeskMate/`.

```bash
cd ~/Library/Application\ Support/DeskMate
echo 'sk-proj-your-real-key' > api-key-openai
chmod 600 api-key-openai
echo '{ "selected": "openai" }' > providers.json
```

That is the whole setup. All three jobs then run on `gpt-5.6-sol`, a current model that picks its own reasoning depth, so there is no `models` block to write. Add one only if you want something different — see [Other combinations](#other-combinations) below.

Three things worth knowing about those commands.

**Settings cannot save the key for you.** That screen checks what you paste against Anthropic's key format and always writes Anthropic's file, so there is no OpenAI field to look for. Hence `api-key-openai` by hand.

**The `chmod` matters.** The file holds a secret, and nothing enforces the mode when you create it yourself. The newline `echo` leaves behind does not matter, since the key is trimmed when read.

**Do not reach for `OPENAI_API_KEY` in your shell.** An app you double-click inherits launchd's environment rather than your terminal's, so an exported variable is invisible to it — which is the whole reason these key files exist. The variable works only if you launch DeskMate from a terminal.

To confirm it took, open Settings. When the active provider is not Anthropic, a banner reads "Analyze is using OpenAI" and tells you the key on that screen is Anthropic's and is not in use. That banner is your check, since `config-print` below only exists if you build from source. The change applies to your next *Analyze*.

Your Anthropic key keeps its original name, `api-key`, so none of this disturbs it and switching back is a one-line edit with no key to re-enter.

### Other combinations

To name a particular model, without changing anything else:

```json
{ "providers": { "anthropic": { "models": { "reasoning": "claude-opus-5" } } } }
```

Three jobs, three models. Labeling runs on every session and wants something cheap, reasoning is the one that writes the suggestions, narration writes the daily summary. Name only the jobs you care about and the rest keep their defaults.

To run a model inside your own network and still get suggestions written for ChatGPT:

```json
{
  "selected": "acme-vpc",
  "ecosystem": "openai",
  "providers": {
    "acme-vpc": {
      "displayName": "Acme internal vLLM",
      "baseURL": "https://llm.internal.acme.corp/v1",
      "auth": "none",
      "models": {
        "labeling":  "Qwen3-8B-Instruct",
        "reasoning": "Qwen3-72B-Instruct",
        "narration": "Qwen3-72B-Instruct"
      }
    }
  }
}
```

A provider of your own has to give a `baseURL` and all three models, since there is nothing to guess. `auth` is `bearer`, `none`, or `header`.

`ecosystem` takes `claude`, `openai`, or `neutral`. Pick `neutral` and suggestions stop naming any platform at all — you get shell scripts, scheduled jobs, and the app's own API, which is the honest answer when the model is one you host yourself. Leave `ecosystem` out and it follows `selected`.

Nothing secret goes in this file, so it is safe to paste into a bug report. Keys stay in their own `0600` files beside it. If you get the file wrong, DeskMate says so and refuses to run rather than quietly falling back and spending against the wrong key.

To see what your file actually did, build from source and run:

```bash
.build/release/DeskMateFixture config-print
```

It prints the provider, the model chosen for each of the three jobs, and which platform your suggestions will target — without calling the API or spending anything.

---

## What it does

**The agent** runs locally and takes a screenshot every 30 seconds while you are not idle. It records the frontmost app, the window title and the browser URL, OCRs the screenshot on-device with Vision, redacts personal information, and writes to a local database. The screenshot stays on disk and is deleted after 30 days.

**The dashboard** reconstructs workflows out of those rows. It shows where the hours went and which apps and sites ate them, and which sequences you repeat often enough to be worth handing over. Each suggestion carries a confidence score and the step-by-step procedure it thinks you follow, so you can read it back and disagree with it.

**What I actually want it to do, and it does not yet:** once you turn a suggestion into an automation, count how often that automation really runs. That number is the only honest measure of whether an AI rollout worked, and almost no company has it. It is the reason this repo exists, and it is not built. Deskmate today reconstructs the work and proposes the automation; the counting is the next thing I am writing.

## Privacy

This is a tool that watches your screen. You should be suspicious of it. Here is everything, plainly:

- **The capture path never touches the network.** 
- **There is no telemetry.** Nothing reports back to the developer. Everything is hosted locally. 
- **Your data is one file**, at `~/Library/Application Support/DeskMate/deskmate.sqlite`, with the screenshots beside it in `screenshots/`. Open it with any SQLite browser. Delete the lot with `rm -rf ~/Library/Application\ Support/DeskMate`.
- **Your API key is a `0600` file** in that same folder, at `api-key` — readable by your account and nobody else. Not the Keychain, because the nightly summary job runs unattended and Keychain access from a second binary would stop to ask a question at 23:59. `ANTHROPIC_API_KEY` still overrides it, though only for a copy launched from a terminal — a double-clicked app never sees your shell's environment. Any other provider you configure keeps its key in the same shape, at `api-key-openai` and so on. Remove it from Settings, or with `rm ~/Library/Application\ Support/DeskMate/api-key`.
- **Personal info gets redacted.** Things like email addresses, 13–16 digit card numbers, US SSNs, `password:` and `api_key:` lines, `sk-` API keys, and hex tokens of 32 characters or more.
- **What does leave the machine, and only when you ask for it:** clicking *Analyze* sends text digests to whichever model provider you configured — the Claude API unless you changed it, and an endpoint of your own choosing if you did. It sends app names, URL hosts and paths, window titles, and a roughly 200 character redacted OCR snippet per session.

## Current limitations

- **macOS only**
- **Adoption counting does not exist.** 
- **Analysis is not continuous.** Suggestions are only as good as the last time you pressed *Analyze*. Nothing re-runs on its own.

## Where it is going

**computer use**, so a saved workflow can run instead of only being described; **agent count**, so we keep track of how many agents users created and running; 

If you have run this for a week and it told you something true, I would like to hear about it. Open an issue, or write to me at jolieni@hconsult.ai.

## Documentation

[`docs/reference.md`](docs/reference.md) has the build details, the analysis pipeline stage by stage, the full provider and ecosystem configuration, every tunable and environment variable, and the test harness. The team hub has [its own README](server/README.md).

## License

MIT. See [LICENSE](LICENSE).
