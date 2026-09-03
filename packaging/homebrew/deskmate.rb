# typed: strict
# frozen_string_literal: true

# Homebrew cask for DeskMate.
#
# This file belongs in a tap repository, not here — Homebrew reads casks from
# `Casks/` in a repo named `homebrew-<tap>`. Copy it to
# `Jolie-Ni/homebrew-tap/Casks/deskmate.rb` on release; it lives in this repo so
# the version and checksum are updated in the same commit as the build that
# produced them.
#
#   brew install --cask jolie-ni/tap/deskmate
#
# Homebrew quarantines every download, but that is harmless now the builds are
# notarized: Gatekeeper checks the stapled ticket, finds it valid, and lets the
# app open. No `xattr` dance, which is just as well — Homebrew 6 removed the
# `--no-quarantine` flag that used to be the alternative.
cask "deskmate" do
  version "0.1.1"
  sha256 "7e6f4b086f53fb9fadd9107faebd94b614d73affab2f283fffe2e99bcbaea252"

  url "https://github.com/Jolie-Ni/DeskMate/releases/download/v#{version}/DeskMate-#{version}.dmg"
  name "DeskMate"
  desc "Watches how you work and suggests which parts to automate"
  homepage "https://github.com/Jolie-Ni/DeskMate"

  # Bare symbol, not ">= :sonoma": a cask's `depends_on macos:` already
  # defaults to a >= comparator, and the string form is deprecated.
  depends_on macos: :sonoma

  app "DeskMate.app"

  uninstall launchctl: "com.hconsult.deskmate.summary",
            quit:      "com.hconsult.deskmate",
            # The recorder is a separate, non-bundled process that deliberately
            # outlives the dashboard, so `quit:` does not reach it and `signal:`
            # cannot name it — that directive takes bundle IDs, and the daemon
            # has none. pkill on its path is the only thing that actually stops
            # it. Failure is fine: not running is the outcome we wanted.
            script:    {
              executable:   "/usr/bin/pkill",
              args:         ["-f", "DeskMate.app/Contents/MacOS/DeskMateDaemon"],
              must_succeed: false,
            }

  # Left behind on uninstall, deliberately: this is the database of your own
  # captures and the API key. `brew uninstall --zap` removes it, so deleting
  # your data stays an explicit act.
  zap trash: [
    "~/Library/Application Support/DeskMate",
    "~/Library/LaunchAgents/com.hconsult.deskmate.summary.plist",
    "~/Library/Logs/deskmate-summary.log",
    "~/Library/Preferences/com.hconsult.deskmate.plist",
  ]
end
