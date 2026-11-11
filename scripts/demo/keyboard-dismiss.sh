#!/bin/bash
# Demo and checks: keyboard dismiss. With the keyboard up,
# every action other than typing puts it away first: the drawer button, an edge drag, a sheet.
# Everything runs against the in-process FakeBridge (scenarios `YES` and `pickers`); no DSH is needed.
#
#   scripts/demo/keyboard-dismiss.sh          KeyboardDismissUITests, then the seam: ShellUITests (shell,
#                                drawer, the tap and swipe on the new session)
#   DSHM_RESUME=1               skip the parts that passed for the same code (lib.sh demo_part)
#
# Resources, read from the environment (scripts/slice-env):
#   DSHM_SIM dshm-keyboard-dismiss   DSHM_DD (DerivedData) /tmp/dshm-keyboard-dismiss-dd
#   (DSHM_BRIDGE_PORT 47810, DSHM_WEB_PORT 3283, DSHM_HOME ~/.dshm/home-keyboard-dismiss are unused here.)
# Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
for a in "$@"; do echo "unknown arg $a" >&2; exit 2; done
export DSHM_SIM="${DSHM_SIM:-dshm-keyboard-dismiss}" DSHM_DD="${DSHM_DD:-/tmp/dshm-keyboard-dismiss-dd}"
step() { printf '\n== %s\n' "$*"; }
source scripts/demo/lib.sh
LOGS=/tmp/dshm-s24; mkdir -p "$LOGS"
SIM="$DSHM_SIM"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi

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

ui_part s24 KeyboardDismissUITests
# The seam: the shell, the drawer and the new session's own tap and swipe (04a3d0e).
ui_part shell-seam ShellUITests

step "keyboard-dismiss demo passed"
