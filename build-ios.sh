#!/bin/sh
# Builds the Rust core for iPad, generates the Swift bindings, and packages
# ios/Generated/PadCoreFFI.xcframework.
#   ./build-ios.sh                    # debug, device + Apple-silicon simulator
#   ./build-ios.sh --release          # optimized
#   ./build-ios.sh --release --device # optimized, real iPad only (half the time/disk)
#   ./build-ios.sh --sim              # Apple-silicon simulator only
set -eu
cd "$(dirname "$0")"
. "$HOME/.cargo/env"

PROFILE=debug
FLAG=
TARGETS="aarch64-apple-ios aarch64-apple-ios-sim"
for arg in "$@"; do
  case "$arg" in
    --release) PROFILE=release; FLAG=--release ;;
    --device) TARGETS=aarch64-apple-ios ;;
    --sim) TARGETS=aarch64-apple-ios-sim ;;
    *) echo "unknown option $arg" >&2; exit 2 ;;
  esac
done
export IPHONEOS_DEPLOYMENT_TARGET=17.0

for target in $TARGETS; do
  cargo build -p padcore --lib $FLAG --target "$target"
done

OUT=ios/Generated
rm -rf "$OUT"
mkdir -p "$OUT/headers"
cargo run -q -p padcore --features bindgen --bin uniffi-bindgen -- \
  generate --library "target/${TARGETS%% *}/$PROFILE/libpadcore.a" \
  --language swift --out-dir "$OUT/bindings"

mv "$OUT/bindings/padcore.swift" "$OUT/padcore.swift"
mv "$OUT/bindings/padcoreFFI.h" "$OUT/headers/"
# xcodebuild wants the modulemap named module.modulemap
mv "$OUT/bindings/padcoreFFI.modulemap" "$OUT/headers/module.modulemap"
rm -rf "$OUT/bindings"

LIBS=
for target in $TARGETS; do
  LIBS="$LIBS -library target/$target/$PROFILE/libpadcore.a -headers $OUT/headers"
done
# shellcheck disable=SC2086
xcodebuild -create-xcframework $LIBS -output "$OUT/PadCoreFFI.xcframework" >/dev/null
rm -rf "$OUT/headers"
echo "built $OUT/PadCoreFFI.xcframework ($PROFILE: $TARGETS)"
