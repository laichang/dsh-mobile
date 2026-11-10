#!/bin/bash
# Keyboard demo and checks: the keyboard goes away before any action that is
# not typing. With the keyboard up on 01 and two hosts, the host menu and the "+" menu put it away
# first, then show. App only: two in-process FakeBridge hosts (-DSHMFakeBridge multi
# -DSHMFakeScenario attachments); no DSH and no bridge.
#
#   scripts/demo/keyboard.sh              KeyboardMenusUITests (testHostMenuPutsKeyboardAwayFirst,
#                                         testAttachMenuPutsKeyboardAwayFirst), then the seam:
#                                         KeyboardDismissUITests (drawer, edge drag, sheets)
#   scripts/demo/keyboard.sh --shots DIR  also write the screenshots (1/3 size) into DIR
#   DSHM_RESUME=1                         skip the parts that passed for the same code (lib.sh demo_part)
#
# Resources (WORKFLOW.md §6), read from the environment (scripts/slice-env): DSHM_SIM, DSHM_DD
# (DerivedData, default /tmp/dshm-keyboard-dd). Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=""
while [ $# -gt 0 ]; do case "$1" in
  --shots) SHOTS="${2:?--shots needs a directory}"; shift 2 ;;
  *) echo "unknown arg $1" >&2; exit 2 ;;
esac; done
: "${DSHM_SIM:?run eval \"\$(scripts/slice-env <ID>)\" first}"
export DSHM_DD="${DSHM_DD:-/tmp/dshm-keyboard-dd}"
step() { printf '\n== %s\n' "$*"; }
source scripts/demo/lib.sh
LOGS=/tmp/dshm-keyboard-$(basename "$DSHM_SIM"); mkdir -p "$LOGS"
SIM="$DSHM_SIM"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
SHOT_DIR="$(mktemp -d)"
trap 'rm -rf "$SHOT_DIR"' EXIT
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR"

step "build the app and UI tests ($SIM; log: $LOGS/build.log)"
scripts/xc build-for-testing -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DSHM_DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  --log "$LOGS/build.log" || { grep -E "error:" "$LOGS/build.log"; exit 1; }

ui() { # part name, log, then -only-testing selectors
  local name=$1 log=$2; shift 2
  local args=() t
  for t in "$@"; do args+=("-only-testing:dsh-mobileUITests/$t"); done
  if demo_part "$name" scripts/xc test-without-building -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile \
      -destination "$DEST" -derivedDataPath "$DSHM_DD" -parallel-testing-enabled NO "${args[@]}" --log "$log"; then
    grep -E "Test Case.*(passed|failed|skipped)" "$log" || true
  else
    grep -E "error:|Test Case.*(passed|failed)" "$log" || tail -30 "$log"
    echo "UI tests failed ($log)" >&2; exit 1
  fi
  demo_no_skipped_ui "$log"
}

step "UI: keyboard up on 01, then the host menu and the + menu (log: $LOGS/ui-menus.log)"
ui keyboard-ui-menus "$LOGS/ui-menus.log" KeyboardMenusUITests

step "UI: the seam: the drawer, an edge drag and the picker sheets (log: $LOGS/ui-shell.log)"
ui keyboard-ui-shell "$LOGS/ui-shell.log" KeyboardDismissUITests

if [ -n "$SHOTS" ]; then
  step "screenshots → $SHOTS (1/3 size)"
  mkdir -p "$SHOTS"
  for f in "$SHOT_DIR"/keyboard-*.png; do
    [ -e "$f" ] || { echo "no new shots (the UI parts were skipped)"; break; }
    out="$SHOTS/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
step "keyboard demo passed"
