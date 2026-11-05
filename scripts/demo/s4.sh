#!/bin/bash
# S4 acceptance on real DSH and an iOS Simulator. Only the fixture under mktemp is a deletion target.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47810}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3283}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home-s4}"
SIM="${DSHM_SIM:-dshm-S4}"
export PATH="$HOME/.dshm/bin:$HOME/.nvm/versions/node/v24.14.0/bin:$PATH"
source scripts/demo/lib.sh
LOGS=/tmp/dshm-s4; mkdir -p "$LOGS"
FIXTURE=$(mktemp -d)
mkdir -p "$DSHM_HOME"
# Keep X1's loopback test-control plugin out of the normal DSH profile.
PROFILE=$(mktemp -d "$DSHM_HOME/approval-demo.XXXXXX")
PID=""
cleanup() { if [ -n "$PID" ]; then kill "$PID" 2>/dev/null || true; wait "$PID" || true; fi; rm -rf "$FIXTURE" "$PROFILE"; }
trap cleanup EXIT
mkdir "$FIXTURE/tmp"; echo 'S4 fixture' > "$FIXTURE/tmp/x"
export DSHM_S4_COMMAND="rm '$FIXTURE/tmp/x'"
demo_prepare_bridge
demo_bridge_tests "$LOGS/bridge-test.log"
demo_swift_tests "$LOGS/swift-test.log"
DSHM_HOME="$PROFILE" node scripts/demo/s4-host.mjs > "$LOGS/host.log" 2>&1 &
PID=$!
for _ in $(seq 1 180); do
  grep -q 's4-host: ready' "$LOGS/host.log" && break
  kill -0 "$PID" 2>/dev/null || { tail -20 "$LOGS/host.log"; exit 1; }
  sleep 0.5
done
grep -q 's4-host: ready' "$LOGS/host.log" || { echo "S4 host did not become ready"; exit 1; }
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
export TEST_RUNNER_DSHM_S4_CONTROL="$(awk '/^s4-host: ready / { print $3; exit }' "$LOGS/host.log")"
export TEST_RUNNER_DSHM_BRIDGE_PORT="$DSHM_BRIDGE_PORT" TEST_RUNNER_DSHM_S4_COMMAND="$DSHM_S4_COMMAND"
export TEST_RUNNER_DSHM_SHOT_DIR="$FIXTURE"
xcodebuild test -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "${DSHM_DD:-/tmp/dshm-s4-dd}" -parallel-testing-enabled NO -jobs 4 \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -only-testing:dsh-mobileUITests/S4ApprovalUITests \
  > "$LOGS/uitest.log" 2>&1 || { grep -E 'error:|Test Case' "$LOGS/uitest.log" | tail -24; exit 1; }
grep -E 'Test Case.*(passed|failed|skipped)' "$LOGS/uitest.log"
demo_no_skipped_ui "$LOGS/uitest.log"
test "$(cat "$FIXTURE/tmp/x")" = 'S4 fixture'
if [ "${1:-}" = --shots ]; then
  mkdir -p evidence/S4
  for f in "$FIXTURE"/*.png; do sips --resampleWidth 402 "$f" --out "evidence/S4/$(basename "$f")" >/dev/null; done
fi
echo 'S4 demo passed'
