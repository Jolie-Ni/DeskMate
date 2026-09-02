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
#   brew install --cask --no-quarantine jolie-ni/tap/deskmate
#
# The flag is not optional while the build is unnotarized: Homebrew quarantines
# casks by default, so without it the app hits the same Gatekeeper wall as a
# browser download. A cask cannot waive that on the user's behalf, by design.
# What the cask does buy is one command instead of a trip through System
# Settings, plus a clean uninstall path.
cask "deskmate" do
  version "0.1.0"
  sha256 "595c2a64ea76188433b416c28b21062b1ca30987e47dc0b147ee0cb86b8bc452"

  url "https://github.com/Jolie-Ni/DeskMate/releases/download/v#{version}/DeskMate-#{version}.dmg"
  name "DeskMate"
  desc "Watches how you work and suggests which parts to automate"
  homepage "https://github.com/Jolie-Ni/DeskMate"

  depends_on macos: ">= :sonoma"

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
