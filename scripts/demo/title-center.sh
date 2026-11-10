#!/bin/bash
# Demo and checks: page title centering. The title and the subtitle of the
# page bar are centered on the screen on each page: new session, a session page, 所有任务. A long
# title truncates clear of the drawer button.
# Everything runs against the in-process FakeBridge (scenario `YES`); no DSH is needed.
#
#   scripts/demo/title-center.sh          TitleCenterUITests, then the seam: ShellUITests (shell,
#                                drawer, the page bar's drawer button)
#   DSHM_RESUME=1               skip the parts that passed for the same code (lib.sh demo_part)
#
# Resources (WORKFLOW.md §6), read from the environment:
#   DSHM_SIM dshm-title-center   DSHM_DD (DerivedData) /tmp/dshm-title-center-dd
#   (DSHM_BRIDGE_PORT 47810, DSHM_WEB_PORT 3283, DSHM_HOME ~/.dshm/home-title-center are unused here.)
# Screenshots go to evidence/title-center/ (title-center-*.png).
# Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
for a in "$@"; do echo "unknown arg $a" >&2; exit 2; done
export DSHM_SIM="${DSHM_SIM:-dshm-title-center}" DSHM_DD="${DSHM_DD:-/tmp/dshm-title-center-dd}"
step() { printf '\n== %s\n' "$*"; }
source scripts/demo/lib.sh
LOGS=/tmp/dshm-s26; mkdir -p "$LOGS"
SIM="$DSHM_SIM"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
SHOT_DIR="$(mktemp -d)"
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR"

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

ui_part s26 TitleCenterUITests
if compgen -G "$SHOT_DIR/title-center-*.png" > /dev/null; then
  mkdir -p ${DSHM_EVIDENCE:-evidence/title-center} && cp "$SHOT_DIR"/title-center-*.png ${DSHM_EVIDENCE:-evidence/title-center}/
  echo "screenshots: ${DSHM_EVIDENCE:-evidence/title-center}/"
fi
# The seam: the shell, the drawer and the page bar's drawer button.
ui_part shell-seam ShellUITests

step "title-center demo passed"
