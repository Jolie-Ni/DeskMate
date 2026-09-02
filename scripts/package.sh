#!/bin/bash
#
# Builds DeskMate.app and wraps it in a DMG.
#
#   ./scripts/package.sh              → ad-hoc signed, works today
#   DESKMATE_SIGN_ID="Developer ID Application: Name (TEAMID)" \
#   DESKMATE_NOTARY_PROFILE=deskmate \
#   ./scripts/package.sh              → signed, notarized, stapled
#
# The two paths are deliberately the same script. Notarization needs a paid
# Apple Developer Program membership, which can take weeks to come through;
# until it does, the ad-hoc path ships something real, and the day the
# certificate arrives this becomes two environment variables rather than a
# rewrite.
#
# Set up the notary profile once, with an app-specific password from
# appleid.apple.com:
#
#   xcrun notarytool store-credentials deskmate \
#     --apple-id you@example.com --team-id TEAMID --password xxxx-xxxx-xxxx-xxxx
#
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

DIST="$REPO/dist"
APP="$DIST/DeskMate.app"

# Reassigned below if the universal path is taken, which puts products
# somewhere else entirely.
BUILD="$REPO/.build/release"

# A tag is the source of truth; a working copy that has never been tagged still
# has to produce something installable, so fall back rather than fail.
VERSION="${DESKMATE_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo v0.1.0)}"
VERSION="${VERSION#v}"
# CFBundleVersion has to increase monotonically and be numeric. Commit count is
# both, and needs no bookkeeping.
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }

# ---------------------------------------------------------------- build

# A universal binary needs SwiftPM's xcbuild path, which ships with Xcode and
# not with the Command Line Tools. Rather than fail on a CLT-only machine, build
# native and say so: CI has Xcode, and the release that reaches users comes from
# there. A local DMG is for testing the packaging, not for shipping.
XCBUILD="$(xcode-select -p 2>/dev/null)/../SharedFrameworks/XCBuild.framework/Versions/A/Support/xcbuild"
if [ -x "$XCBUILD" ]; then
    say "Building DeskMate $VERSION (build $BUILD_NUMBER) — universal"
    swift build -c release --arch arm64 --arch x86_64
    BUILD="$REPO/.build/apple/Products/Release"
else
    warn "Command Line Tools only — building for $(uname -m) alone."
    warn "Install Xcode for a universal binary. CI already produces one."
    say "Building DeskMate $VERSION (build $BUILD_NUMBER)"
    swift build -c release
fi

# ---------------------------------------------------------------- assemble

say "Assembling DeskMate.app"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# All three executables land in Contents/MacOS together, because DaemonControl
# finds the daemon as a sibling of whoever is asking. Splitting them into
# Helpers/ would be tidier and would break launching the recorder.
for exe in DeskMateDashboard DeskMateDaemon DeskMateSummary; do
    cp "$BUILD/$exe" "$APP/Contents/MacOS/$exe"
done

# SwiftPM resource bundles. Bundle.module looks in Bundle.main.resourceURL
# first, which is Contents/Resources inside an app.
for bundle in "$BUILD"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
done

cp "$REPO/packaging/DeskMate.icns" "$APP/Contents/Resources/DeskMate.icns"

sed -e "s|__SHORT_VERSION__|$VERSION|" \
    -e "s|__BUILD_VERSION__|$BUILD_NUMBER|" \
    "$REPO/packaging/Info.plist" > "$APP/Contents/Info.plist"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# ---------------------------------------------------------------- sign

ENTITLEMENTS="$REPO/packaging/DeskMate.entitlements"

if [ -n "${DESKMATE_SIGN_ID:-}" ]; then
    say "Signing with: $DESKMATE_SIGN_ID"
    SIGN_ARGS=(--sign "$DESKMATE_SIGN_ID" --options runtime --timestamp
               --entitlements "$ENTITLEMENTS")
else
    warn "No DESKMATE_SIGN_ID — ad-hoc signing."
    warn "Users will need System Settings → Privacy & Security → Open Anyway."
    # No --options runtime: the hardened runtime demands the Apple-events
    # entitlement be backed by a real identity, and an ad-hoc signature is not
    # one. Without the runtime, browser URL capture keeps working.
    SIGN_ARGS=(--sign - )
fi

# Inside out. Signing the bundle first and its contents second invalidates the
# outer signature, and codesign will not tell you.
# Only bundles that carry an Info.plist are nested *code* as far as codesign is
# concerned. SwiftPM emits resource-only bundles as a flat directory with no
# plist, and codesign rejects those outright ("bundle format unrecognized") —
# they are sealed by the app's own resource envelope instead.
for b in "$APP"/Contents/Resources/*.bundle; do
    [ -e "$b" ] || continue
    if [ -f "$b/Info.plist" ] || [ -f "$b/Contents/Info.plist" ]; then
        codesign --force "${SIGN_ARGS[@]}" "$b"
    fi
done
for exe in DeskMateDaemon DeskMateSummary DeskMateDashboard; do
    codesign --force "${SIGN_ARGS[@]}" "$APP/Contents/MacOS/$exe"
done
codesign --force "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# ---------------------------------------------------------------- notarize

if [ -n "${DESKMATE_NOTARY_PROFILE:-}" ]; then
    if [ -z "${DESKMATE_SIGN_ID:-}" ]; then
        echo "DESKMATE_NOTARY_PROFILE is set but DESKMATE_SIGN_ID is not." >&2
        echo "Apple will not notarize an ad-hoc signature." >&2
        exit 1
    fi
    say "Notarizing the app"
    ZIP="$DIST/DeskMate-notarize.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$DESKMATE_NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
fi

# ---------------------------------------------------------------- dmg

say "Building the disk image"
DMG="$DIST/DeskMate-$VERSION.dmg"
STAGING="$DIST/staging"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/DeskMate.app"
# The drop target. Without it people run the app from the mounted image, where
# it is read-only and every relaunch re-prompts for Screen Recording.
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "DeskMate" -srcfolder "$STAGING" \
    -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGING"

if [ -n "${DESKMATE_SIGN_ID:-}" ]; then
    codesign --force --sign "$DESKMATE_SIGN_ID" --timestamp "$DMG"
fi
if [ -n "${DESKMATE_NOTARY_PROFILE:-}" ]; then
    say "Notarizing the disk image"
    xcrun notarytool submit "$DMG" --keychain-profile "$DESKMATE_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

say "Done: $DMG"
shasum -a 256 "$DMG"

if [ -z "${DESKMATE_NOTARY_PROFILE:-}" ]; then
    cat <<'NOTE'

This build is not notarized. On macOS 15 and later a download of it opens with
"DeskMate is damaged and can't be opened" — Gatekeeper's wording for unsigned,
not a corrupt file. Users get past it with:

    System Settings → Privacy & Security → scroll down → Open Anyway

or, from a terminal:

    xattr -dr com.apple.quarantine /Applications/DeskMate.app

Homebrew does NOT avoid this on its own — it quarantines casks by default. The
install line that opens cleanly is:

    brew install --cask --no-quarantine <tap>/deskmate
NOTE
fi
