#!/bin/sh
# The shippable build, in the order Apple's checks need: release build signed with the team's Developer ID →
# notarize the app → staple it → wrap it in the disk image → sign and notarize the image → staple that too →
# prove Gatekeeper accepts what came out. Prints the image's path, and nothing else, on stdout.
#
#   scripts/release.sh
#
# It publishes nothing. Attaching the image to a GitHub release is a separate, deliberate step:
#   gh release create <version> build/MySidepulse-<version>.dmg --title "MySidepulse <version>"
#
# One-time setup, both by the Wooflab team's Account Holder:
#   • a "Developer ID Application" certificate for the team in this Mac's keychain
#   • xcrun notarytool store-credentials <profile> --key <AuthKey.p8> --key-id <id> --issuer <issuer>
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/signing.env"
. "$ROOT/scripts/no-leftovers.sh"

BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"

# Everything that can be missing is named before anything is built.
[ -n "$SIGN_IDENTITY" ] || {
    echo "no 'Developer ID Application' certificate for team $TEAM_ID in the keychain." >&2
    echo "The Wooflab Account Holder creates it: Xcode › Settings › Accounts › Wooflab › Manage Certificates › + › Developer ID Application." >&2
    exit 1
}
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || {
    echo "no notarytool keychain profile '$NOTARY_PROFILE'. Store one from an App Store Connect API key:" >&2
    echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --key <AuthKey_XXXX.p8> --key-id <KEY_ID> --issuer <ISSUER_ID>" >&2
    exit 1
}
[ -z "$(git -C "$ROOT" status --porcelain)" ] || echo "warning: the working tree is dirty" >&2

# A signed bundle sits in build/ for the whole run below. Spotlight must not see it while it is going.
never_indexed "$BUILD"

echo "building ${APP_NAME}…" >&2
sh "$ROOT/scripts/make-app.sh" >&2
[ -d "$APP" ] || { echo "the build produced no bundle" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$BUILD/$APP_NAME-$VERSION.dmg"
ZIP="$BUILD/$APP_NAME-$VERSION.zip"
rm -f "$DMG" "$ZIP"

# The build is only trusted once it says, itself, what it was signed with.
codesign --verify --deep --strict --verbose=2 "$APP" >/dev/null 2>&1 \
    || { echo "the built app does not verify" >&2; codesign --verify --deep --strict --verbose=2 "$APP" >&2; exit 1; }

# Read once into a variable rather than piping: `grep -q` closes the pipe on its first match, `codesign`
# dies of SIGPIPE, and a shell that reports a pipeline's last failure would call that a failed check.
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
case "$SIGNATURE" in
    *"Authority=Developer ID Application: "*"($TEAM_ID)"*) ;;
    *) echo "the built app is not signed with a Developer ID Application certificate for $TEAM_ID:" >&2
       echo "$SIGNATURE" >&2; exit 1 ;;
esac
case "$SIGNATURE" in
    *"flags=0x10000(runtime)"*) ;;
    *) echo "the built app was not signed with the Hardened Runtime, which notarization requires:" >&2
       echo "$SIGNATURE" >&2; exit 1 ;;
esac
ENTITLEMENTS="$(codesign -d --entitlements - "$APP" 2>/dev/null || true)"
case "$ENTITLEMENTS" in
    *get-task-allow*) echo "the built app carries com.apple.security.get-task-allow; it must not ship" >&2; exit 1 ;;
esac
# The runtime refuses an Apple Event without this, and the terminal-tab question is how an alert clears only
# the session of the tab that was looked at.
case "$ENTITLEMENTS" in
    *automation.apple-events*) ;;
    *) echo "the built app does not carry com.apple.security.automation.apple-events;" >&2
       echo "under the Hardened Runtime it could not ask the terminal which tab is visible" >&2; exit 1 ;;
esac

# The app is notarized on its own so that the copy dragged out of the image carries its own ticket, and does
# not need the network to be trusted.
echo "notarizing the app…" >&2
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait > "$BUILD/notarize-app.log" 2>&1 || true
cat "$BUILD/notarize-app.log" >&2
case "$(cat "$BUILD/notarize-app.log")" in
    *"status: Accepted"*) ;;
    *) ID="$(awk '/^  id: /{print $2; exit}' "$BUILD/notarize-app.log")"
       [ -n "$ID" ] && xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
       echo "the app was not notarized" >&2; exit 1 ;;
esac
xcrun stapler staple "$APP" >&2
rm -f "$ZIP"

echo "building the disk image…" >&2
sh "$ROOT/scripts/make-dmg.sh" "$APP" "$DMG" >/dev/null

# The image is signed and notarized in its turn, so that the download itself opens without a warning.
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG" >&2
echo "notarizing the disk image…" >&2
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait > "$BUILD/notarize-dmg.log" 2>&1 || true
cat "$BUILD/notarize-dmg.log" >&2
case "$(cat "$BUILD/notarize-dmg.log")" in
    *"status: Accepted"*) ;;
    *) ID="$(awk '/^  id: /{print $2; exit}' "$BUILD/notarize-dmg.log")"
       [ -n "$ID" ] && xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
       echo "the disk image was not notarized" >&2; exit 1 ;;
esac
xcrun stapler staple "$DMG" >&2

# What a first download actually meets, asked of the system that will meet it.
xcrun stapler validate "$DMG" >&2
VERDICT="$(spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1 || true)"
case "$VERDICT" in
    *accepted*) ;;
    *) echo "Gatekeeper does not accept the disk image:" >&2; echo "$VERDICT" >&2; exit 1 ;;
esac
VERDICT="$(spctl -a -vv -t exec "$APP" 2>&1 || true)"
case "$VERDICT" in
    *accepted*) ;;
    *) echo "Gatekeeper does not accept the app:" >&2; echo "$VERDICT" >&2; exit 1 ;;
esac

# Only the image survives. The .app it was built from is launchable, and leaving it in build/ beside the
# image is exactly the leftover scripts/install.sh and scripts/publish.sh exist to prevent — the disk image
# is the deliverable; the app inside it is what they ditto out of the image again.
rm -rf "$APP"

echo "$DMG"
