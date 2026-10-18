#!/bin/sh
# Runs the in-app end-to-end scenario and screenshots each `SHOT`.
#   ./run-scenario.sh [steps] [outdir]       on the iPad (USB or Wi-Fi; must be unlocked)
#   PADCODE_SIM=1 ./run-scenario.sh [steps]  in the iPad Simulator (never locks)
# steps: all | lsp,split,… (see ios/Sources/Scenario.swift)
set -u
DEVICE=${PADCODE_DEVICE:-00008132-0001482E1121801C}
SIM=${PADCODE_SIM_DEVICE:-473D5B5C-85EC-4C7B-AC0A-96CFA39C9C43}
STEPS=${1:-all}
OUT=${2:-$HOME/Library/Caches/padcode-scenario}
mkdir -p "$OUT"
rm -f "$OUT"/*.png "$OUT/log.txt"
if [ -n "${PADCODE_SIM:-}" ]; then
  xcrun simctl boot "$SIM" 2>/dev/null
  # The Simulator sometimes stops passing SIMCTL_CHILD_ variables and the app's
  # stdout, so the steps also go in a one-shot file and the app logs to a file.
  TMP="$(xcrun simctl get_app_container "$SIM" com.mashburnkansana.padcode data)/tmp"
  rm -f "$TMP/padcode-scenario.log"
  printf '%s' "$STEPS" > "$TMP/padcode-scenario"
  SIMCTL_CHILD_PADCODE_SCENARIO="$STEPS" xcrun simctl launch --console-pty --terminate-running-process \
    "$SIM" com.mashburnkansana.padcode >"$OUT/console.txt" 2>&1 &
  sync_log() { cp "$TMP/padcode-scenario.log" "$OUT/log.txt" 2>/dev/null || :; }
  shot() { xcrun simctl io "$SIM" screenshot "$1" >/dev/null 2>&1; }
else
  # A locked screen refuses the launch (even while lockState says no passcode is
  # needed yet): retry for up to PADCODE_UNLOCK_WAIT seconds.
  waited=0
  while :; do
    xcrun devicectl device process launch --console --terminate-existing \
      -e "{\"PADCODE_SCENARIO\":\"$STEPS\"}" --device "$DEVICE" com.mashburnkansana.padcode \
      >"$OUT/log.txt" 2>&1 &
    LAUNCH=$!
    # Running (app output) or refused (the launch command exits): whichever comes first.
    for _ in $(seq 1 30); do
      grep -q "\[scenario\]" "$OUT/log.txt" 2>/dev/null && break
      kill -0 $LAUNCH 2>/dev/null || break
      sleep 1
    done
    grep -q "BSErrorCodeDescription = Locked" "$OUT/log.txt" 2>/dev/null || break
    [ "$waited" -eq 0 ] && echo "iPad is locked; unlock it to start the run…" >&2
    [ "$waited" -ge "${PADCODE_UNLOCK_WAIT:-600}" ] && break
    wait $LAUNCH 2>/dev/null; sleep 4; waited=$((waited + 8))
  done
  shot() { xcrun devicectl device capture screenshot --device "$DEVICE" --destination "$1" >/dev/null 2>&1; }
  sync_log() { :; }
fi
[ -n "${PADCODE_SIM:-}" ] && LAUNCH=$!
seen=0
deadline=$(( $(date +%s) + ${PADCODE_TIMEOUT:-600} ))
while kill -0 $LAUNCH 2>/dev/null && [ "$(date +%s)" -lt "$deadline" ]; do
  sync_log
  n=$(grep -c '\[scenario\] SHOT ' "$OUT/log.txt" 2>/dev/null || true)
  while [ "$seen" -lt "${n:-0}" ]; do
    seen=$((seen + 1))
    name=$(grep '\[scenario\] SHOT ' "$OUT/log.txt" | sed -n "${seen}p" | sed 's/.*SHOT //' | tr -d '\r')
    shot "$OUT/$(printf %02d $seen)-$name.png"
  done
  grep -q '\[scenario\] DONE' "$OUT/log.txt" && break
  sleep 0.5
done
kill $LAUNCH 2>/dev/null
sync_log
grep '\[scenario\]' "$OUT/log.txt" | grep -v ' SHOT ' | sed 's/.*\[scenario\]/[scenario]/'
ls "$OUT"/*.png 2>/dev/null | wc -l | xargs echo screenshots:
