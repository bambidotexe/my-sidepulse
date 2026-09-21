#!/bin/sh
# **Install locally.** One of the two ways a build of this app ever reaches a Mac.
#
#   scripts/install.sh
#
# Builds the same signed, notarized, stapled production bundle a release ships, at the version the rule in
# scripts/version.sh gives, puts it in /Applications, registers the launch agent and the hooks, and hands the
# live process to launchd. Leaves nothing behind: when this script returns there is no .app and no .dmg
# anywhere under the repository, so nothing but /Applications can be launched by Spotlight, opened by the
# Finder, or started by launchd.
#
# The other way is scripts/publish.sh, which does all of this and puts the disk image on GitHub as well.
#
# There is no third way. An ad-hoc, unsigned build (SIGN_IDENTITY="-") is for reading something a signed
# build will not show; it is never installed, and scripts/make-app.sh refuses to make one without
# DEBUG_OK=1 — that is the owner's call, not a way to skip this script.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/signing.env"
. "$ROOT/scripts/version.sh"
. "$ROOT/scripts/no-leftovers.sh"

DEST="/Applications/$APP_NAME.app"

# A reinstall is not a person asking for the Settings window. The marker is written **before anything can
# start the app**, and the first launch that finds it opens nothing; the copy that stays removes it
# (Sources/MySidepulseCore/QuietLaunch.swift). It lapses on its own after two minutes.
QUIET_DIR="$HOME/Library/Application Support/MySidepulse"
/bin/mkdir -p "$QUIET_DIR"
: > "$QUIET_DIR/quiet-launch"
AGENT="io.mysidepulse.agent"
CLI="$DEST/Contents/MacOS/mysidepulse"
MOUNT=""

# Whatever happens — a failed build, a failed verify, an interrupt — the repository is left with nothing
# launchable in it. This runs on the way out of every path through the script.
cleanup() {
  if [ -n "$MOUNT" ] && [ -d "$MOUNT" ]; then
    /usr/bin/hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
  fi
  no_leftovers "$ROOT"
}
trap cleanup EXIT INT TERM

VERSION="$(version_tree)"
echo "installing $APP_NAME $VERSION" >&2

DMG="$("$ROOT/scripts/release.sh")"

# --------------------------------------------------------------------------------------------------------
# The bundle that goes to /Applications is the one inside the disk image, so what is installed is exactly
# what a release would hand a stranger — stapled ticket and all.
# --------------------------------------------------------------------------------------------------------
MOUNT="$(mktemp -d)"
/usr/bin/hdiutil attach "$DMG" -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" >/dev/null

# **Boot the job out, do not kill it.** `killall` is a SIGTERM, which is a non-zero exit, which is exactly
# what `KeepAlive/SuccessfulExit = false` exists to restart: launchd would bring the app back from the old
# bundle while this script is still replacing it, and the `open` below would then reach an instance that had
# never seen the quiet-launch marker. `bootout` unloads the job and takes its process with it, and nothing
# comes back until the app bootstraps the job again on the launch below. It is never `disable`, which is
# permanent (docs/pitfalls.md).
launchctl bootout "gui/$(id -u)/$AGENT" 2>/dev/null || true
killall MySidepulseApp 2>/dev/null || true
rm -rf "$DEST"
/usr/bin/ditto "$MOUNT/$APP_NAME.app" "$DEST"
/usr/bin/hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
MOUNT=""

# What was installed says for itself what it is. A bundle that fails this must not be left in /Applications.
codesign --verify --deep --strict "$DEST" 2>/dev/null || { echo "the installed bundle does not verify" >&2; rm -rf "$DEST"; exit 1; }
INSTALLED="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist")"
[ "$INSTALLED" = "$VERSION" ] || { echo "installed $INSTALLED, expected $VERSION" >&2; exit 1; }
xcrun stapler validate "$DEST" >/dev/null 2>&1 || echo "warning: the installed bundle carries no stapled ticket" >&2

# --------------------------------------------------------------------------------------------------------
# One `open`, and the app does the rest itself. A launch that did not come from the agent writes
# ~/Library/LaunchAgents/io.mysidepulse.agent.plist, bootstraps the job, then hands over: it starts a helper
# and quits, and the helper kickstarts the job so that what runs is what launchd supervises
# (docs/functional.md, Handing over to launchd). An app started by `open` is nobody's job, and KeepAlive
# only supervises the instance launchd spawned itself, so that hand-over is what buys the crash restart.
# This script used to do it from outside, with killall and `kickstart -k`; a copy dragged out of the disk
# image has nobody to run those, which is why it became the app's own job.
# --------------------------------------------------------------------------------------------------------
open "$DEST"

# Wait for the job to have a process. A pid in the first column is the whole proof; a dash is the job
# loaded and idle, which is the state the hand-over exists to get out of.
i=0
while [ $i -lt 150 ]; do
  case "$(launchctl list 2>/dev/null | grep "$AGENT" || true)" in
    [0-9]*) break ;;
  esac
  sleep 0.2
  i=$((i + 1))
done
case "$(launchctl list 2>/dev/null | grep "$AGENT" || true)" in
  [0-9]*) ;;
  *) echo "WARNING: the app runs, but launchd is not supervising it, so a crash would not be recovered." >&2
     echo "         Settings > Startup says the same, and doctor has the detail." >&2 ;;
esac

"$CLI" install-hooks
"$CLI" doctor || true

echo "" >&2
echo "Optional: expose the CLI on PATH with:" >&2
echo "  sudo ln -sf '$CLI' /usr/local/bin/mysidepulse" >&2

echo "$DEST"
