#!/bin/bash
# iOS release for registered devices: archive → development-signed IPA →
# OTA manifest + AltStore source → GitHub release → optional over-the-air share.
#
# Usage: Scripts/release-ios.sh [all|build|publish|share]...
#   default: all (= build publish). `share` is opt-in: it serves the IPA through
#   icodesign/remote-installer (https://github.com/icodesign/remote-installer)
#   as a temporary HTTPS install link + QR code, and blocks until the link
#   expires or you press Ctrl-C.
#
# The archive is signed with Xcode's automatic team profile, so the IPA installs
# only on devices registered to team DH5UQL44AR. Register a new iPhone in the
# developer portal (and rebuild) before sharing to it.
#
# Updates: every release carries manifest.plist and altstore.json, both reached
# through the .../releases/latest/download/ permalink, so:
#   - registered devices install and update over the air: the in-app updater
#     opens the release's manifest through itms-services://, and a first install
#     is `itms-services://?action=download-manifest&url=$LATEST/manifest.plist`
#     pasted into Safari;
#   - any other device adds $LATEST/altstore.json as an AltStore / SideStore
#     source, which re-signs the IPA with the user's Apple ID and updates it.
#
# Optional environment:
#   GH_REPO        GitHub repo for the release (default: CatStudioApp/kumone)
#   SHARE_EXPIRY   how long the share link lives (default: 2h)
#   SHARE_ARGS     extra `remote-installer share` flags, e.g. "--max-downloads 1"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

APP_NAME="Kumone"
GH_REPO="${GH_REPO:-CatStudioApp/kumone}"
SHARE_EXPIRY="${SHARE_EXPIRY:-2h}"
DIST="$ROOT/dist"
WORK="$ROOT/.build/ios-release"
ARCHIVE="$WORK/KumoneIOS.xcarchive"

# One version for both platforms: build-app.sh is the source of truth.
VERSION="$(sed -n 's/^MARKETING_VERSION="\(.*\)"$/\1/p' "$SCRIPT_DIR/build-app.sh")"
[ -n "$VERSION" ] || { echo "error: cannot read MARKETING_VERSION from build-app.sh" >&2; exit 1; }
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
IPA="$DIST/$APP_NAME-iOS-$VERSION.ipa"
MANIFEST="$DIST/manifest.plist"
ALTSTORE="$DIST/altstore.json"
LATEST="https://github.com/$GH_REPO/releases/latest/download"

log() { printf '\n==> %s\n' "$*"; }

stage_build() {
  log "Archiving iOS $VERSION ($BUILD_NUMBER)"
  rm -rf "$WORK" && mkdir -p "$WORK" "$DIST"
  xcodebuild archive \
    -workspace ios/KumoneIOS.xcworkspace -scheme KumoneIOS -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    > "$WORK/archive.log" 2>&1 || { tail -40 "$WORK/archive.log" >&2; exit 1; }

  # Package the archived .app directly: it already carries the team profile
  # Xcode signed it with, and `-exportArchive` needs an Apple ID in Xcode to
  # mint an ad-hoc profile.
  local app="$ARCHIVE/Products/Applications/KumoneIOS.app"
  codesign --verify --deep --strict "$app"
  security cms -D -i "$app/embedded.mobileprovision" > "$WORK/profile.plist"
  echo "profile: $(/usr/libexec/PlistBuddy -c 'Print :Name' "$WORK/profile.plist")," \
    "$(/usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$WORK/profile.plist" | grep -c '^    ') devices"

  mkdir -p "$WORK/payload/Payload"
  cp -R "$app" "$WORK/payload/Payload/"
  rm -f "$IPA"
  (cd "$WORK/payload" && zip -qry "$IPA" Payload)
  echo "$IPA ($(du -h "$IPA" | cut -f1))"

  # OTA manifest for itms-services://. It points at this version's IPA, not the
  # latest/ permalink, so an old manifest never installs a newer build than it
  # describes. The bundle id comes from the signed app, which is what iOS checks.
  local bundle_id
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
  cat > "$MANIFEST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>items</key>
  <array>
    <dict>
      <key>assets</key>
      <array>
        <dict>
          <key>kind</key><string>software-package</string>
          <key>url</key><string>https://github.com/$GH_REPO/releases/download/v$VERSION/$(basename "$IPA")</string>
        </dict>
      </array>
      <key>metadata</key>
      <dict>
        <key>bundle-identifier</key><string>$bundle_id</string>
        <key>bundle-version</key><string>$VERSION</string>
        <key>kind</key><string>software</string>
        <key>title</key><string>$APP_NAME</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
PLIST
  plutil -lint "$MANIFEST"

  "$SCRIPT_DIR/release-notes.sh" "$VERSION" > "$WORK/notes.md"
  BUILD_NUMBER="$BUILD_NUMBER" GITHUB_REPOSITORY="$GH_REPO" \
    bash "$SCRIPT_DIR/altstore-source.sh" "$VERSION" "$IPA" "$WORK/notes.md" > "$ALTSTORE"
  python3 -m json.tool "$ALTSTORE" >/dev/null
  echo "$MANIFEST, $ALTSTORE"
}

stage_publish() {
  local f
  for f in "$IPA" "$MANIFEST" "$ALTSTORE"; do
    [ -f "$f" ] || { echo "error: no $f; run the build stage first" >&2; exit 1; }
  done
  log "Publishing $(basename "$IPA") to $GH_REPO v$VERSION"
  if gh release view "v$VERSION" --repo "$GH_REPO" >/dev/null 2>&1; then
    gh release upload "v$VERSION" "$IPA" "$MANIFEST" "$ALTSTORE" --repo "$GH_REPO" --clobber
  else
    gh release create "v$VERSION" "$IPA" "$MANIFEST" "$ALTSTORE" --repo "$GH_REPO" \
      --title "$VERSION" --notes "$("$SCRIPT_DIR/release-notes.sh" "$VERSION")"
  fi
  echo "OTA install (paste into Safari): itms-services://?action=download-manifest&url=$LATEST/manifest.plist"
  echo "AltStore / SideStore source:     $LATEST/altstore.json"
}

stage_share() {
  [ -f "$IPA" ] || { echo "error: no IPA at $IPA; run the build stage first" >&2; exit 1; }
  command -v remote-installer >/dev/null || {
    echo "error: remote-installer not found: brew install icodesign/tap/remote-installer" >&2; exit 1; }
  log "Sharing $(basename "$IPA") for $SHARE_EXPIRY"
  # shellcheck disable=SC2086
  remote-installer share "$IPA" --expire-after "$SHARE_EXPIRY" ${SHARE_ARGS:-}
}

STAGES=("$@")
[ ${#STAGES[@]} -gt 0 ] || STAGES=(all)
for stage in "${STAGES[@]}"; do
  case "$stage" in
    all) stage_build; stage_publish ;;
    build|publish|share) "stage_$stage" ;;
    *) echo "error: unknown stage '$stage'" >&2; exit 1 ;;
  esac
done
