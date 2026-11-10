#!/bin/bash
# S23 demo and checks: drawer motion and landing positions (design screens F1–F4).
# Re-runnable evidence for S23's Done when items. Everything runs against the in-process
# FakeBridge (scenarios `outcomes` and `coding`); no DSH is needed.
#
#   scripts/demo/s23.sh          swift test, S23DrawerMotionUITests, then the seams: S19OutcomesUITests
#                                (landing position), S16SessionPageUITests (session page),
#                                S14DrawerUITests (FakeBridge part) and T1ShellUITests (drawer),
#                                S18ApprovalSheetUITests and S15AllTasksUITests (05 after the motion)
#   scripts/demo/s23.sh --shots  also refresh the screenshots in evidence/S23/ (1/3 size)
#   DSHM_RESUME=1               skip the parts that passed for the same code (lib.sh demo_part)
#
# Resources (WORKFLOW.md §6), read from the environment:
#   DSHM_SIM dshm-S23   DSHM_DD (DerivedData) /tmp/dshm-s23-dd
#   (DSHM_BRIDGE_PORT 47811, DSHM_WEB_PORT 3284, DSHM_HOME ~/.dshm/home-s23 are S23's, unused here.)
# Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0
for a in "$@"; do case "$a" in --shots) SHOTS=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
export DSHM_SIM="${DSHM_SIM:-dshm-S23}" DSHM_DD="${DSHM_DD:-/tmp/dshm-s23-dd}"
step() { printf '\n== %s\n' "$*"; }
source scripts/demo/lib.sh
LOGS=/tmp/dshm-s23; mkdir -p "$LOGS"
SIM="$DSHM_SIM"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
SHOT_DIR="$(mktemp -d)"
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR"

step "DSHKit tests (swift test)"
demo_swift_tests "$LOGS/swift-test.log"

step "build the app and UI tests ($SIM)"
scripts/xc build-for-testing -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DSHM_DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  --log "$LOGS/build.log" || { grep -E "error:" "$LOGS/build.log"; exit 1; }

# One part per UI test class (lib.sh demo_part): a failure in one does not run the others again.
ui_part() { # name, then -only-testing selectors
  local name=$1; shift
  local args=() t
  for t in "$@"; do args+=("-only-testing:dsh-mobileUITests/$t"); done
  step "UI: $name (log: $LOGS/ui-$name.log)"
  if demo_part "ui-$name" scripts/xc test-without-building -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile \
      -destination "$DEST" -derivedDataPath "$DSHM_DD" -parallel-testing-enabled NO "${args[@]}" \
      --log "$LOGS/ui-$name.log"; then
    grep -E "Test Case.*(passed|failed|skipped)" "$LOGS/ui-$name.log" || true
  else
    grep -E "error:|Test Case.*(passed|failed)" "$LOGS/ui-$name.log" || tail -30 "$LOGS/ui-$name.log"
    echo "UI tests failed: $name" >&2
    exit 1
  fi
  demo_no_skipped_ui "$LOGS/ui-$name.log"
}

# Copy the screenshots right after the S23 part, so a failure in a later part does not lose them.
copy_shots() {
  [ $SHOTS = 1 ] || return 0
  step "screenshots → evidence/S23 (1/3 size)"
  mkdir -p evidence/S23
  for f in "$SHOT_DIR"/s23-*.png; do
    [ -f "$f" ] || { echo "no S23 screenshots (a part was skipped with DSHM_RESUME=1?)" >&2; exit 1; }
    out="evidence/S23/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
}

ui_part s23 S23DrawerMotionUITests
copy_shots
# The seams (this slice lands after S14): the same drawer and session page.
ui_part s19-seam S19OutcomesUITests
ui_part s16-seam S16SessionPageUITests
ui_part s14-seam S14DrawerUITests/testDrawerGroupsByHostAndWorkspaceWithStatusMarks \
  S14DrawerUITests/testBadgeCountMatchesWaitingOnMe S14DrawerUITests/testOfflineHostSessionsOpenFromTheCache \
  S14DrawerUITests/testWithoutDrawerCapabilityShowsHostAndSession
ui_part t1-seam T1ShellUITests
# 05 waits for the motion (S18's PendingApprovalBar); the 03 approval card opens its session.
ui_part s18-seam S18ApprovalSheetUITests
ui_part s15-seam S15AllTasksUITests

step "S23 demo passed"
