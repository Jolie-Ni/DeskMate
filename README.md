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

Builds are not notarized yet — Apple charges $99/year for the certificate that allows it, so macOS treats DeskMate as unsigned. That costs you one extra step, whichever way you install.

**With Homebrew:**

```bash
brew install --cask jolie-ni/tap/deskmate
xattr -dr com.apple.quarantine /Applications/DeskMate.app
```

The second line is doing real work: Homebrew marks every download as quarantined, and macOS refuses to launch a quarantined app it cannot verify. Removing the flag says you accept an unsigned binary from this repo — the same question this whole app asks you to answer. Skip it and you get the "damaged" dialog below instead.

**Or download the app**: grab `DeskMate.dmg` from [Releases](https://github.com/Jolie-Ni/DeskMate/releases), open it, and drag DeskMate to Applications. The first launch says *"DeskMate is damaged and can't be opened."* It is not damaged; that is Gatekeeper's wording for unsigned. Open it once via **System Settings → Privacy & Security → Open Anyway**, and it never asks again.

On first launch DeskMate asks for your Anthropic API key and checks it against the API before saving. You can skip it — capture never touches the network and works with no key at all — and add one later in Settings.

Then press **Start**, top right. That spawns the capture daemon; **Stop** ends it. Closing the window does not stop recording — stopping is meant to be a deliberate act.

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

## What it does

**The agent** runs locally and takes a screenshot every 30 seconds while you are not idle. It records the frontmost app, the window title and the browser URL, OCRs the screenshot on-device with Vision, redacts personal information, and writes to a local database. The screenshot stays on disk and is deleted after 30 days.

**The dashboard** reconstructs workflows out of those rows. It shows where the hours went and which apps and sites ate them, and which sequences you repeat often enough to be worth handing over. Each suggestion carries a confidence score and the step-by-step procedure it thinks you follow, so you can read it back and disagree with it.

**What I actually want it to do, and it does not yet:** once you turn a suggestion into an automation, count how often that automation really runs. That number is the only honest measure of whether an AI rollout worked, and almost no company has it. It is the reason this repo exists, and it is not built. Deskmate today reconstructs the work and proposes the automation; the counting is the next thing I am writing.

## Privacy

This is a tool that watches your screen. You should be suspicious of it. Here is everything, plainly:

- **The capture path never touches the network.** 
- **There is no telemetry.** Nothing reports back to the developer. Everything is hosted locally. 
- **Your data is one file**, at `~/Library/Application Support/DeskMate/deskmate.sqlite`, with the screenshots beside it in `screenshots/`. Open it with any SQLite browser. Delete the lot with `rm -rf ~/Library/Application\ Support/DeskMate`.
- **Your API key is a `0600` file** in that same folder, at `api-key` — readable by your account and nobody else. Not the Keychain, because the nightly summary job runs unattended and Keychain access from a second binary would stop to ask a question at 23:59. `ANTHROPIC_API_KEY` still overrides it when set. Remove it from Settings, or with `rm ~/Library/Application\ Support/DeskMate/api-key`.
- **Personal info gets redacted.** Things like email addresses, 13–16 digit card numbers, US SSNs, `password:` and `api_key:` lines, `sk-` API keys, and hex tokens of 32 characters or more.
- **What does leave the machine, and only when you ask for it:** clicking *Analyze* sends text digests to the Claude API: app names, URL hosts and paths, window titles, and a roughly 200 character redacted OCR snippet per session.

## Current limitations

- **macOS only**
- **Not notarized.** First launch needs a trip through System Settings → Privacy & Security, or a `--no-quarantine` install. Screen Recording also has to be re-granted after each update, because the permission is tied to an unsigned build's hash.
- **Adoption counting does not exist.** 
- **Analysis is not continuous.** Suggestions are only as good as the last time you pressed *Analyze*. Nothing re-runs on its own.

## Where it is going

**computer use**, so a saved workflow can run instead of only being described; **agent count**, so we keep track of how many agents users created and running; 

If you have run this for a week and it told you something true, I would like to hear about it. Open an issue, or write to me at jolieni@hconsult.ai.

## Documentation

[`docs/reference.md`](docs/reference.md) has the build details, the analysis pipeline stage by stage, every tunable and environment variable, and the test harness. The team hub has [its own README](server/README.md).

## License

MIT. See [LICENSE](LICENSE).
