#!/bin/sh
# Keeps PadCode running on the iPad despite free-account signing, which expires
# after 7 days. Run daily (see install-refresh.sh): when the profile has fewer
# than $MIN_DAYS left it gets a fresh one, rebuilds, and reinstalls over USB or
# Wi-Fi. App data (sign-in, recent folders) survives a reinstall.
#   ./refresh-ipad.sh          # only if expiring soon
#   ./refresh-ipad.sh --force  # now
set -u
cd "$(dirname "$0")"
. "$HOME/.cargo/env"

DEVICE=${PADCODE_DEVICE:-00008132-0001482E1121801C}
TEAM=$(sed -n 's/^ *DEVELOPMENT_TEAM: *//p' ios/project.yml)
BUNDLE=$(sed -n 's/^ *PRODUCT_BUNDLE_IDENTIFIER: *//p' ios/project.yml)
MIN_DAYS=${PADCODE_MIN_DAYS:-4}
PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
DERIVED="$HOME/Library/Caches/padcode-build"
APP="$DERIVED/Build/Products/Release-iphoneos/PadCode.app"

log() { echo "$(date '+%F %T') $*"; }
notify() { osascript -e "display notification \"$1\" with title \"PadCode refresh\"" >/dev/null 2>&1; }
fail() { log "FAILED: $1"; notify "$1"; exit 1; }

# Profile(s) Xcode made for this app, and how long the newest one lasts.
profiles_for_app() {
  for p in "$PROFILES"/*.mobileprovision; do
    [ -f "$p" ] || continue
    id=$(security cms -D -i "$p" 2>/dev/null | plutil -extract Entitlements.application-identifier raw -o - - 2>/dev/null)
    [ "$id" = "$TEAM.$BUNDLE" ] && echo "$p"
  done
}

days_left() {
  profiles_for_app | while IFS= read -r p; do
    exp=$(security cms -D -i "$p" 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null)
    echo $(( ($(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$exp" +%s) - $(date +%s)) / 86400 ))
  done | sort -n | tail -1
}

left=$(days_left)
left=${left:--1}
if [ "${1:-}" != "--force" ] && [ "$left" -ge "$MIN_DAYS" ]; then
  log "profile for $BUNDLE valid ~$left more days; nothing to do"
  exit 0
fi
log "profile has ~$left days left; refreshing"

xcrun devicectl list devices 2>/dev/null | grep -q "$DEVICE.*available" \
  || fail "iPad not reachable (USB or Wi-Fi). Will retry tomorrow."

# A fresh profile = 7 more days. Xcode makes one on the next build. Park the
# old ones rather than deleting them: without an Xcode account the build can't
# make a new one, and the old profile is all that still signs the app.
OLD=$(mktemp -d)
profiles_for_app | while IFS= read -r p; do mv "$p" "$OLD/"; done
restore() { mv "$OLD"/*.mobileprovision "$PROFILES/" 2>/dev/null; fail "$1"; }

./build-ios.sh --release --device || restore "Rust core build failed"
(cd ios && /Users/mashburn/Documents/tools/xcodegen-2.46.0/xcodegen/bin/xcodegen generate -q) || restore "xcodegen failed"
xcodebuild -project ios/PadCode.xcodeproj -scheme PadCode -configuration Release \
  -destination "id=$DEVICE" -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates -skipPackagePluginValidation -skipMacroValidation \
  build >"$DERIVED.log" 2>&1 || restore "app build/signing failed; is an Apple ID signed in under Xcode > Settings > Accounts? (see $DERIVED.log)"
rm -rf "$OLD"

xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null 2>&1 \
  || fail "install on iPad failed. Is it unlocked and on the same Wi-Fi?"

log "installed; profile now valid ~$(days_left) days"
notify "PadCode re-signed for 7 more days"
