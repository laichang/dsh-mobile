#!/bin/bash
# S16 demo and checks: the session page (PLAN.md §5 S16, screen 04). Re-runnable evidence for
# S16's Done when items. Everything runs against the in-process FakeBridge; no DSH is needed.
#
#   scripts/demo/s16.sh          swift test (with the FakeBridge coding task), S16SessionPageUITests,
#                                and the T1 shell and S3 milestone UI tests that use the same page
#   scripts/demo/s16.sh --shots  also refresh the screenshots in evidence/S16/ (1/3 size)
#   DSHM_RESUME=1               skip the parts that passed for the same code (lib.sh demo_part)
#
# Resources (WORKFLOW.md §6), read from the environment:
#   DSHM_SIM dshm-S16   DSHM_DD (DerivedData) /tmp/dshm-s16-dd
#   (DSHM_BRIDGE_PORT 47813, DSHM_WEB_PORT 3286, DSHM_HOME ~/.dshm/home-s16 are S16's, unused here.)
# Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0
for a in "$@"; do case "$a" in --shots) SHOTS=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
export DSHM_SIM="${DSHM_SIM:-dshm-S16}" DSHM_DD="${DSHM_DD:-/tmp/dshm-s16-dd}"
step() { printf '\n== %s\n' "$*"; }
source scripts/demo/lib.sh
LOGS=/tmp/dshm-s16; mkdir -p "$LOGS"
SIM="$DSHM_SIM"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
SHOT_DIR="$(mktemp -d)"
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR"

step "DSHKit tests (swift test, FakeBridge coding task)"
demo_swift_tests "$LOGS/swift-test.log"

step "build the app and UI tests ($SIM)"
xcodebuild build-for-testing -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DSHM_DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  > "$LOGS/build.log" 2>&1 || { grep -E "error:" "$LOGS/build.log"; exit 1; }

# One part per UI test class (lib.sh demo_part): a failure in one does not run the others again.
ui_part() { # name, then -only-testing selectors
  local name=$1; shift
  local args=() t
  for t in "$@"; do args+=("-only-testing:dsh-mobileUITests/$t"); done
  step "UI: $name (log: $LOGS/ui-$name.log)"
  if demo_part "ui-$name" xcodebuild test-without-building -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile \
      -destination "$DEST" -derivedDataPath "$DSHM_DD" -parallel-testing-enabled NO "${args[@]}" \
      > "$LOGS/ui-$name.log" 2>&1; then
    grep -E "Test Case.*(passed|failed|skipped)" "$LOGS/ui-$name.log" || true
  else
    grep -E "error:|Test Case.*(passed|failed)" "$LOGS/ui-$name.log" || tail -30 "$LOGS/ui-$name.log"
    echo "UI tests failed: $name" >&2
    exit 1
  fi
  demo_no_skipped_ui "$LOGS/ui-$name.log"
}

ui_part s16 S16SessionPageUITests
ui_part shell T1ShellUITests \
  S3MilestonesUITests/testTodosTickOffOnCardWithFakeBridge \
  S3MilestonesUITests/testTimelineWithFakeBridge \
  S3MilestonesUITests/testNoMilestonesNoCard \
  S2DurableListUITests/testCachedMilestonesAfterKillAndReopenWithFakeBridge

if [ $SHOTS = 1 ]; then
  step "screenshots → evidence/S16 (1/3 size)"
  mkdir -p evidence/S16
  for f in "$SHOT_DIR"/s16-*.png; do
    [ -f "$f" ] || { echo "no S16 screenshots (a part was skipped with DSHM_RESUME=1?)" >&2; exit 1; }
    out="evidence/S16/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
step "S16 demo passed"
