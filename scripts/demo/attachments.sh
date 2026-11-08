#!/bin/bash
# Attachments demo and checks (ARCHITECTURE D95): attach one photo on composer 01, send a task,
# and the DSH session has the image.
#
#   scripts/demo/attachments.sh          bridge tests + DSHKit tests (golden photo), then
#                                        AttachmentsUITests on a real DSH + bridge with the mock
#                                        model, then a check of the DSH session log for the image
#   scripts/demo/attachments.sh --shots DIR  also write the screenshots (1/3 size) into DIR
#   DSHM_RESUME=1                        skip the parts that passed for the same code (lib.sh demo_part)
#
# The golden photo (protocol/fixtures/attachments/photo.jpg) is added to the simulator's photo
# library first, so the picker shows it as the newest photo.
#
# Resources (WORKFLOW.md §6), read from the environment (scripts/slice-env):
#   DSHM_SIM, DSHM_DD (DerivedData, default /tmp/dshm-attachments-dd), DSHM_BRIDGE_PORT,
#   DSHM_WEB_PORT, DSHM_HOME. Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=""
while [ $# -gt 0 ]; do case "$1" in --shots) SHOTS="${2:?--shots needs a directory}"; shift 2 ;; *) echo "unknown arg $1" >&2; exit 2 ;; esac; done
: "${DSHM_SIM:?run eval \"\$(scripts/slice-env <ID>)\" first}"
: "${DSHM_BRIDGE_PORT:?}" "${DSHM_WEB_PORT:?}" "${DSHM_HOME:?}"
export DSHM_DD="${DSHM_DD:-/tmp/dshm-attachments-dd}"
NODE24="$HOME/.nvm/versions/node/v24.14.0/bin"
[ -d "$NODE24" ] && export PATH="$NODE24:$PATH"
[ -d "$HOME/.dshm/bin" ] && export PATH="$HOME/.dshm/bin:$PATH"
step() { printf '\n== %s\n' "$*"; }
source scripts/demo/lib.sh
LOGS=/tmp/dshm-attachments; mkdir -p "$LOGS"
SIM="$DSHM_SIM"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
SHOT_DIR="$(mktemp -d)"
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR"

demo_prepare_bridge
step "bridge tests (node:test, FakeDSH, golden photo)"
demo_part attachments-bridge-test bash -c 'source scripts/demo/lib.sh; demo_bridge_tests "$1"' _ "$LOGS/bridge-test.log"
step "DSHKit tests (swift test, FakeBridge, golden photo)"
demo_part attachments-swift-test bash -c 'source scripts/demo/lib.sh; demo_swift_tests "$1"' _ "$LOGS/swift-test.log"

step "build the app and UI tests ($SIM)"
xcodebuild build-for-testing -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DSHM_DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  > "$LOGS/build.log" 2>&1 || { grep -E "error:" "$LOGS/build.log"; exit 1; }

step "the golden photo into the simulator's library"
xcrun simctl addmedia "$SIM" protocol/fixtures/attachments/photo.jpg

DSH_PID=""
trap '[ -n "$DSH_PID" ] && kill "$DSH_PID" 2>/dev/null || true' EXIT
(cd bridge && corepack pnpm build >/dev/null)
step "real DSH + bridge (web $DSHM_WEB_PORT, bridge $DSHM_BRIDGE_PORT, $DSHM_HOME)"
mkdir -p "$DSHM_HOME"
if lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null 2>&1; then echo "port $DSHM_BRIDGE_PORT is in use" >&2; exit 1; fi
node scripts/dsh-up.mjs > "$LOGS/dsh-up.log" 2>&1 &
DSH_PID=$!
for _ in $(seq 1 240); do lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.5; done
lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null || { tail -20 "$LOGS/dsh-up.log"; echo "bridge did not come up" >&2; exit 1; }
SINCE="$(date +%s)"

step "UI: attach one photo on 01 and send (log: $LOGS/ui.log)"
export TEST_RUNNER_DSHM_REAL_DSH=1 TEST_RUNNER_DSHM_BRIDGE_PORT="$DSHM_BRIDGE_PORT"
if demo_part attachments-ui xcodebuild test-without-building -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile \
    -destination "$DEST" -derivedDataPath "$DSHM_DD" -parallel-testing-enabled NO \
    -only-testing:dsh-mobileUITests/AttachmentsUITests/testAttachOnePhotoAndSend > "$LOGS/ui.log" 2>&1; then
  grep -E "Test Case.*(passed|failed|skipped)" "$LOGS/ui.log" || true
else
  grep -E "error:|Test Case.*(passed|failed)" "$LOGS/ui.log" || tail -30 "$LOGS/ui.log"
  echo "UI test failed" >&2; exit 1
fi
demo_no_skipped_ui "$LOGS/ui.log"

step "the DSH session has the image"
if [ "${DSHM_RESUME:-0}" = 1 ] && ! grep -q "Test Case.*passed" "$LOGS/ui.log"; then SINCE=0; fi
node scripts/demo/attachments-check.mjs "$DSHM_HOME" "$SINCE"
kill "$DSH_PID" 2>/dev/null || true; wait "$DSH_PID" 2>/dev/null || true; DSH_PID=""

if [ -n "$SHOTS" ]; then
  step "screenshots → $SHOTS (1/3 size)"
  mkdir -p "$SHOTS"
  for f in "$SHOT_DIR"/attachments-*.png; do
    [ -e "$f" ] || { echo "no new shots (the UI part was skipped)"; break; }
    out="$SHOTS/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
step "attachments demo passed"
