#!/bin/bash
# The Live Activity of a running task on the lock screen (screen L).
# FakeBridge in the app (`-DSHMFakeScenario live-activity`): three todos, five seconds apart. The UI
# test starts the task, locks the Simulator, reads the activity on the lock screen (title, host,
# latest step, a time that ticks), unlocks, waits for the end, and reads it again as done.
#
#   scripts/demo/live-activity.sh            DSHKit tests (FakeActivitySystem), then the UI test
#   scripts/demo/live-activity.sh --shots    also refresh the screenshots in evidence/live-activity/
#   scripts/demo/live-activity.sh --ui-only  only the UI test
#   scripts/demo/live-activity.sh --keep     keep the screenshots and the lock screen dumps (prints where)
#
# Resources (scripts/slice-env): DSHM_SIM, DSHM_DD. No DSH and no bridge port: the fake is in the app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0; UI_ONLY=0; KEEP=0
for a in "$@"; do case "$a" in --shots) SHOTS=1 ;; --ui-only) UI_ONLY=1 ;; --keep) KEEP=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
SIM="${DSHM_SIM:-iPhone 17 Pro}"
export PATH="$HOME/.dshm/bin:$HOME/.nvm/versions/node/v24.14.0/bin:$PATH"
source scripts/demo/lib.sh
LOGS=/tmp/dshm-live-activity-${DSHM_BRIDGE_PORT:-47800}; mkdir -p "$LOGS"
SHOTDIR=$(mktemp -d)
cleanup() { if [ $KEEP = 1 ]; then echo "shots and dumps: $SHOTDIR"; else rm -rf "$SHOTDIR"; fi; }
trap cleanup EXIT

if [ $UI_ONLY = 0 ]; then
  printf '\n== %s\n' "DSHKit tests (swift test, FakeBridge, FakeActivitySystem)"
  demo_swift_tests "$LOGS/swift-test.log"
  grep -q "Suite LiveActivityTests passed" "$LOGS/swift-test.log" || { echo "LiveActivityTests did not run" >&2; exit 1; }
fi

printf '\n== %s\n' "UI test in the Simulator ($SIM): the lock screen"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOTDIR"
scripts/xc test -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "${DSHM_DD:-/tmp/dshm-live-activity-dd}" -parallel-testing-enabled NO -jobs 4 \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -only-testing:dsh-mobileUITests/LiveActivityUITests \
  --log "$LOGS/uitest.log" || { grep -E 'error:|Test Case|XCTAssert|failed' "$LOGS/uitest.log" | tail -24; exit 1; }
grep -E 'Test Case.*(passed|failed|skipped)' "$LOGS/uitest.log"
demo_no_skipped_ui "$LOGS/uitest.log"
if [ $SHOTS = 1 ]; then
  mkdir -p ${DSHM_EVIDENCE:-evidence/live-activity}
  for f in "$SHOTDIR"/live-activity-*.png; do sips --resampleWidth 402 "$f" --out "${DSHM_EVIDENCE:-evidence/live-activity}/$(basename "$f")" >/dev/null; done
fi
echo 'live activity demo passed'
