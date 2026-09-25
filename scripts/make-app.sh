#!/bin/sh
# Assembles build/MySidepulse.app from the release build and signs it with the Wooflab team's Developer ID,
# under the Hardened Runtime, so that the result can be notarized and opens on a Mac that did not build it.
# SIGN_IDENTITY="-" in the environment signs ad-hoc instead, for a throwaway build that cannot be shipped.
set -eu

VERSION="1.1.1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/signing.env"
APP="$ROOT/build/MySidepulse.app"

swift build -c release --package-path "$ROOT"
BIN="$ROOT/.build/release"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# The GUI binary keeps its build-product name, MySidepulseApp, rather than
# "MySidepulse": Contents/MacOS is on the default case-insensitive APFS volume,
# and a file named "MySidepulse" collides there with "mysidepulse" (the CLI,
# below) — the second cp would silently overwrite the first's bytes. Nothing
# else depends on this on-disk name: the app is found by bundle identifier
# (io.mysidepulse.app) and displayed by CFBundleName/CFBundleDisplayName
# (MySidepulse); only CFBundleExecutable below has to match it.
cp "$BIN/MySidepulseApp" "$APP/Contents/MacOS/MySidepulseApp"
cp "$BIN/mysidepulse" "$APP/Contents/MacOS/mysidepulse"

# The icon ships in two forms. Assets.car, compiled by actool from the Icon
# Composer bundle, is what macOS renders with Liquid Glass; AppIcon.icns is the
# flat form for whatever reads CFBundleIconFile instead of the catalogue.
# Nothing is cached: both are rebuilt every run.
rm -rf "$ROOT/build/icon" "$ROOT/build/AppIcon.iconset" "$ROOT/build/AppIcon.icns"

# actool lives in full Xcode, not the Command Line Tools. Without it the app
# still builds and still has an icon — it just loses the glass on macOS 26+.
if xcrun --find actool >/dev/null 2>&1; then
  mkdir -p "$ROOT/build/icon"
  xcrun actool "$ROOT/Resources/AppIcon.icon" \
    --compile "$ROOT/build/icon" \
    --app-icon AppIcon \
    --output-partial-info-plist "$ROOT/build/icon/partial.plist" \
    --platform macosx --minimum-deployment-target 26.0 \
    --output-format human-readable-text >/dev/null
  cp "$ROOT/build/icon/Assets.car" "$APP/Contents/Resources/Assets.car"
  ICON_NAME_KEY='    <key>CFBundleIconName</key><string>AppIcon</string>'
else
  echo "WARNING: actool not found (needs full Xcode) — icon built without Liquid Glass"
  ICON_NAME_KEY=''
fi

# actool's own AppIcon.icns carries 16 px and 128 px only; everything larger is
# expected to come from Assets.car. So the .icns is rasterised here from the
# 1024 px master, which already carries the rounded mask an .icns is required
# to bake in.
ICONSET="$ROOT/build/AppIcon.iconset"
mkdir -p "$ICONSET"
for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
            128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 512:icon_256x256@2x \
            512:icon_512x512 1024:icon_512x512@2x; do
  sips -z "${spec%%:*}" "${spec%%:*}" \
    "$ROOT/Resources/previews/mysidepulse-glass-preview-1024.png" \
    --out "$ICONSET/${spec#*:}.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ROOT/build/AppIcon.icns"
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# The two permission sentences macOS shows are the only user-facing text that
# cannot live in the Swift string tables: TCC reads them from the bundle, not
# from the running app. So they ship as .lproj/InfoPlist.strings, which is also
# what makes the app appear in System Settings > Language & Region's per-app
# language list. The Info.plist keys below stay as the English fallback for a
# system whose language matches neither.
for lproj in en fr; do
  mkdir -p "$APP/Contents/Resources/$lproj.lproj"
done
cat > "$APP/Contents/Resources/en.lproj/InfoPlist.strings" <<'STRINGS'
"NSRemovableVolumesUsageDescription" = "MySidepulse writes to the LED strip, which mounts as a removable volume.";
"NSAppleEventsUsageDescription" = "MySidepulse asks your terminal which tab is visible, so seeing an alert only clears that tab's session.";
STRINGS
cat > "$APP/Contents/Resources/fr.lproj/InfoPlist.strings" <<'STRINGS'
"NSRemovableVolumesUsageDescription" = "MySidepulse écrit sur le ruban LED, qui est monté comme un volume amovible.";
"NSAppleEventsUsageDescription" = "MySidepulse demande à votre terminal quel onglet est visible, pour qu'un coup d'œil sur une alerte n'efface que la session de cet onglet.";
STRINGS

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>MySidepulseApp</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
${ICON_NAME_KEY}
    <key>CFBundleIdentifier</key><string>io.mysidepulse.app</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>fr</string></array>
    <key>CFBundleName</key><string>MySidepulse</string>
    <key>CFBundleDisplayName</key><string>MySidepulse</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Personal build.</string>
    <key>NSRemovableVolumesUsageDescription</key><string>MySidepulse writes to the LED strip, which mounts as a removable volume.</string>
    <key>NSAppleEventsUsageDescription</key><string>MySidepulse asks your terminal which tab is visible, so seeing an alert only clears that tab's session.</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"


# Innermost first: the outer bundle seals what is inside it, so a nested binary re-signed afterwards would
# break that seal. A real identity also gets the Hardened Runtime and a trusted timestamp, both of which
# notarization refuses a build without, and the entitlements the runtime needs to send an Apple Event.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [ "$SIGN_IDENTITY" = "-" ]; then
    # Ad-hoc: it cannot be notarized, and every build gives the app a new code identity, so macOS asks for
    # Automation again. It exists to read something a signed build will not show, and it is never made
    # unless the owner has asked for one: DEBUG_OK=1 is how the caller says so.
    if [ "${DEBUG_OK:-0}" != "1" ]; then
        echo "refusing an ad-hoc build without the owner asking for it." >&2
        echo "An ad-hoc build cannot be notarized and is not a way to install the app: scripts/install.sh is." >&2
        echo "If the owner has asked for one, run: DEBUG_OK=1 sh scripts/make-app.sh" >&2
        exit 1
    fi
    echo "warning: ad-hoc signing — this build cannot be notarized, and every build gives the app a new" >&2
    echo "         code identity, so macOS asks for Automation again. Ship with scripts/release.sh." >&2
    SIGN_FLAGS=""
else
    SIGN_FLAGS="--options runtime --timestamp"
fi
ENTITLEMENTS="$ROOT/Resources/MySidepulse.entitlements"
codesign --force $SIGN_FLAGS --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/mysidepulse"
codesign --force $SIGN_FLAGS --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/MySidepulseApp"
codesign --force $SIGN_FLAGS --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP"

echo "Built $APP"
