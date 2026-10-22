#!/usr/bin/env bash
# Release build of brainmaxxing.app: sign, package as a DMG, notarize and staple.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/release.sh [--help]

Environment variables:
  BM_SIGN_IDENTITY   codesign identity (default "-", ad hoc),
                     e.g. "Developer ID Application: Name (TEAMID)"
  BM_TEAM_ID         optional, passed to xcodebuild as DEVELOPMENT_TEAM
  BM_NOTARY_PROFILE  keychain profile from `xcrun notarytool store-credentials`;
                     when unset, notarization and stapling are skipped
  BM_OUT             output directory, relative to the repo root (default build/release)
USAGE
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then usage; exit 0; fi
if [ $# -gt 0 ]; then usage >&2; exit 2; fi

BM_SIGN_IDENTITY="${BM_SIGN_IDENTITY:--}"
BM_TEAM_ID="${BM_TEAM_ID:-}"
BM_NOTARY_PROFILE="${BM_NOTARY_PROFILE:-}"
BM_OUT="${BM_OUT:-build/release}"

# Work from the repo root no matter where the script is called from.
cd "$(dirname "$0")/.."
mkdir -p "$BM_OUT"
OUT="$(cd "$BM_OUT" && pwd)"

echo "==> xcodegen generate"
xcodegen generate

# Notarization needs a secure timestamp on every signature; ad hoc signing cannot have one.
sign_flags="--options=runtime"
[ "$BM_SIGN_IDENTITY" != "-" ] && sign_flags="--options=runtime --timestamp"

build_args=(
  -project brainmaxxing.xcodeproj -scheme brainmaxxing -configuration Release
  -derivedDataPath "$OUT/DerivedData"
  CODE_SIGN_IDENTITY="$BM_SIGN_IDENTITY" CODE_SIGN_STYLE=Manual
  OTHER_CODE_SIGN_FLAGS="$sign_flags"
)
[ -n "$BM_TEAM_ID" ] && build_args+=(DEVELOPMENT_TEAM="$BM_TEAM_ID")

echo "==> xcodebuild Release (identity: $BM_SIGN_IDENTITY)"
xcodebuild "${build_args[@]}" build

APP="$OUT/DerivedData/Build/Products/Release/brainmaxxing.app"
[ -d "$APP" ] || { echo "error: $APP not found" >&2; exit 1; }

# The post-build script signs the embedded tools without a timestamp, and Sparkle's
# nested helpers may keep the signature they were built with. With a real identity,
# sign everything again with a timestamp, innermost first, then re-seal the app.
if [ "$BM_SIGN_IDENTITY" != "-" ]; then
  echo "==> re-signing embedded tools and Sparkle with a secure timestamp"
  for tool in digest-cli DigestMCP; do
    codesign --force --options runtime --timestamp --sign "$BM_SIGN_IDENTITY" "$APP/Contents/MacOS/$tool"
  done
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  for part in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
    [ -e "$SPARKLE/$part" ] || continue
    codesign --force --options runtime --timestamp --preserve-metadata=entitlements \
      --sign "$BM_SIGN_IDENTITY" "$SPARKLE/$part"
  done
  [ -d "$SPARKLE" ] && codesign --force --options runtime --timestamp --sign "$BM_SIGN_IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
  codesign --force --options runtime --timestamp --preserve-metadata=entitlements \
    --sign "$BM_SIGN_IDENTITY" "$APP"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
echo "==> version $VERSION"

echo "==> codesign --verify"
codesign --verify --deep --strict --verbose=2 "$APP"

# The app is notarized and stapled first, so the copy that goes into the DMG carries
# its ticket; the DMG gets its own ticket afterwards.
if [ -n "$BM_NOTARY_PROFILE" ]; then
  echo "==> notarizing the app (this can take a few minutes)"
  ZIP="$OUT/brainmaxxing-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$BM_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
fi

# Stage the app next to an Applications link so users can drag it across.
DMG="$OUT/brainmaxxing-$VERSION.dmg"
STAGE="$OUT/dmg-staging"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/brainmaxxing.app"
ln -s /Applications "$STAGE/Applications"

echo "==> hdiutil create"
hdiutil create -volname "brainmaxxing $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"

if [ "$BM_SIGN_IDENTITY" != "-" ]; then
  echo "==> signing the DMG"
  codesign --force --timestamp --sign "$BM_SIGN_IDENTITY" "$DMG"
fi

if [ -n "$BM_NOTARY_PROFILE" ]; then
  echo "==> notarizing the DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$BM_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
else
  echo "note: BM_NOTARY_PROFILE is not set, skipping notarization and stapling"
fi

echo "==> DMG: $DMG"
echo "==> spctl --assess (informational for ad hoc builds):"
if spctl --assess --type execute --verbose=2 "$APP" 2>&1; then :; else
  echo "spctl rejected the app (expected for ad hoc or un-notarized builds)"
fi
