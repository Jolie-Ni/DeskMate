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

```bash
git clone https://github.com/Jolie-Ni/DeskMate
cd DeskMate
swift build -c release

export ANTHROPIC_API_KEY=sk-ant-...   # analysis only; capture works without it
.build/release/DeskMateDashboard
```

Press **Start**, top right. That spawns the capture daemon; **Stop** ends it. Closing the window does not stop recording — stopping is meant to be a deliberate act.

Requires **macOS 14 or later** and a **Swift 5.9+ toolchain** (Xcode 15+ or the Command Line Tools). macOS prompts for Screen Recording on first capture, and for Accessibility if you want window titles. Grant them in System Settings → Privacy & Security, then Stop and Start again.

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
- **Personal info gets redacted.** Things like email addresses, 13–16 digit card numbers, US SSNs, `password:` and `api_key:` lines, `sk-` API keys, and hex tokens of 32 characters or more.
- **What does leave the machine, and only when you ask for it:** clicking *Analyze* sends text digests to the Claude API: app names, URL hosts and paths, window titles, and a roughly 200 character redacted OCR snippet per session.

## Current limitations

- **macOS only**
- **No installer.** You need a Swift toolchain and you build from source.
- **Adoption counting does not exist.** 
- **Analysis is not continuous.** Suggestions are only as good as the last time you pressed *Analyze*. Nothing re-runs on its own.

## Where it is going

**computer use**, so a saved workflow can run instead of only being described; **agent count**, so we keep track of how many agents users created and running; 

If you have run this for a week and it told you something true, I would like to hear about it. Open an issue, or write to me at jolieni@hconsult.ai.

## Documentation

[`docs/reference.md`](docs/reference.md) has the build details, the analysis pipeline stage by stage, every tunable and environment variable, and the test harness. The team hub has [its own README](server/README.md).

## License

MIT. See [LICENSE](LICENSE).
