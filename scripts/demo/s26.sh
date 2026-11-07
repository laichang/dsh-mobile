#!/bin/bash
# S26 demo and checks: page title centering (PLAN.md §5 S26). The title and the subtitle of the
# page bar are centered on the screen on each page: new session, a session page, 所有任务. A long
# title truncates clear of the drawer button.
# Everything runs against the in-process FakeBridge (scenario `YES`); no DSH is needed.
#
#   scripts/demo/s26.sh          S26TitleCenterUITests, then the seam: T1ShellUITests (shell,
#                                drawer, the page bar's drawer button)
#   DSHM_RESUME=1               skip the parts that passed for the same code (lib.sh demo_part)
#
# Resources (WORKFLOW.md §6), read from the environment:
#   DSHM_SIM dshm-S26   DSHM_DD (DerivedData) /tmp/dshm-s26-dd
#   (DSHM_BRIDGE_PORT 47810, DSHM_WEB_PORT 3283, DSHM_HOME ~/.dshm/home-s26 are S26's, unused here.)
# Screenshots go to evidence/S26/ (s26-*.png).
# Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
for a in "$@"; do echo "unknown arg $a" >&2; exit 2; done
export DSHM_SIM="${DSHM_SIM:-dshm-S26}" DSHM_DD="${DSHM_DD:-/tmp/dshm-s26-dd}"
step() { printf '\n== %s\n' "$*"; }
source scripts/demo/lib.sh
LOGS=/tmp/dshm-s26; mkdir -p "$LOGS"
SIM="$DSHM_SIM"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
SHOT_DIR="$(mktemp -d)"
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR"

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

ui_part s26 S26TitleCenterUITests
if compgen -G "$SHOT_DIR/s26-*.png" > /dev/null; then
  mkdir -p evidence/S26 && cp "$SHOT_DIR"/s26-*.png evidence/S26/
  echo "screenshots: evidence/S26/"
fi
# The seam: the shell, the drawer and the page bar's drawer button.
ui_part t1-seam T1ShellUITests

step "S26 demo passed"
