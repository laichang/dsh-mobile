#!/bin/bash
# S24 demo and checks: keyboard dismiss (PLAN.md §5 S24, ARCHITECTURE D67). With the keyboard up,
# every action other than typing puts it away first: the drawer button, an edge drag, a sheet.
# Everything runs against the in-process FakeBridge (scenarios `YES` and `pickers`); no DSH is needed.
#
#   scripts/demo/s24.sh          S24KeyboardDismissUITests, then the seam: T1ShellUITests (shell,
#                                drawer, the tap and swipe on the new session)
#   DSHM_RESUME=1               skip the parts that passed for the same code (lib.sh demo_part)
#
# Resources (WORKFLOW.md §6), read from the environment:
#   DSHM_SIM dshm-S24   DSHM_DD (DerivedData) /tmp/dshm-s24-dd
#   (DSHM_BRIDGE_PORT 47810, DSHM_WEB_PORT 3283, DSHM_HOME ~/.dshm/home-s24 are S24's, unused here.)
# Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
for a in "$@"; do echo "unknown arg $a" >&2; exit 2; done
export DSHM_SIM="${DSHM_SIM:-dshm-S24}" DSHM_DD="${DSHM_DD:-/tmp/dshm-s24-dd}"
step() { printf '\n== %s\n' "$*"; }
source scripts/demo/lib.sh
LOGS=/tmp/dshm-s24; mkdir -p "$LOGS"
SIM="$DSHM_SIM"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi

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

ui_part s24 S24KeyboardDismissUITests
# The seam: the shell, the drawer and the new session's own tap and swipe (04a3d0e).
ui_part t1-seam T1ShellUITests

step "S24 demo passed"
