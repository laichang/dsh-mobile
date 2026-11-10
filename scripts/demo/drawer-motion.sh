#!/bin/bash
# Demo and checks: drawer motion and landing positions (design screens F1–F4).
# Re-runnable evidence for its checks. Everything runs against the in-process
# FakeBridge (scenarios `outcomes` and `coding`); no DSH is needed.
#
#   scripts/demo/drawer-motion.sh          swift test, DrawerMotionUITests, then the seams: OutcomesUITests
#                                (landing position), SessionPageUITests (session page),
#                                DrawerUITests (FakeBridge part) and ShellUITests (drawer),
#                                ApprovalSheetUITests and AllTasksUITests (05 after the motion)
#   scripts/demo/drawer-motion.sh --shots  also refresh the screenshots in evidence/drawer-motion/ (1/3 size)
#   DSHM_RESUME=1               skip the parts that passed for the same code (lib.sh demo_part)
#
# Resources (WORKFLOW.md §6), read from the environment:
#   DSHM_SIM dshm-drawer-motion   DSHM_DD (DerivedData) /tmp/dshm-drawer-motion-dd
#   (DSHM_BRIDGE_PORT 47811, DSHM_WEB_PORT 3284, DSHM_HOME ~/.dshm/home-drawer-motion are unused here.)
# Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0
for a in "$@"; do case "$a" in --shots) SHOTS=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
export DSHM_SIM="${DSHM_SIM:-dshm-drawer-motion}" DSHM_DD="${DSHM_DD:-/tmp/dshm-drawer-motion-dd}"
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

# Copy the screenshots right after the drawer motion part, so a failure in a later part does not lose them.
copy_shots() {
  [ $SHOTS = 1 ] || return 0
  step "screenshots → ${DSHM_EVIDENCE:-evidence/drawer-motion} (1/3 size)"
  mkdir -p ${DSHM_EVIDENCE:-evidence/drawer-motion}
  for f in "$SHOT_DIR"/drawer-motion-*.png; do
    [ -f "$f" ] || { echo "no drawer motion screenshots (a part was skipped with DSHM_RESUME=1?)" >&2; exit 1; }
    out="${DSHM_EVIDENCE:-evidence/drawer-motion}/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
}

ui_part s23 DrawerMotionUITests
copy_shots
# The seams: the same drawer and session page.
ui_part outcomes-seam OutcomesUITests
ui_part session-page-seam SessionPageUITests
ui_part drawer-seam DrawerUITests/testDrawerGroupsByHostAndWorkspaceWithStatusMarks \
  DrawerUITests/testBadgeCountMatchesWaitingOnMe DrawerUITests/testOfflineHostSessionsOpenFromTheCache \
  DrawerUITests/testWithoutDrawerCapabilityShowsHostAndSession
ui_part shell-seam ShellUITests
# 05 waits for the motion (the approval sheet's PendingApprovalBar); the 03 approval card opens its session.
ui_part approval-sheet-seam ApprovalSheetUITests
ui_part all-tasks-seam AllTasksUITests

step "drawer-motion demo passed"
