#!/bin/bash
# S18 demo and checks: the approval sheet in a session (PLAN.md §5 S18, DESIGN.md screen 05).
# Re-runnable evidence for S18's Done when items. FakeBridge only: two in-process hosts; Home Mac
# starts with a task that waits on `rm -rf ~/Desktop/Q3/tmp` (`-DSHMFakeBridge approvals`), and a
# new task asks for the same command (`-DSHMFakeAsk`). The Web's answer is a Darwin notification
# to the fake hosts. No DSH and no port is needed.
#
#   scripts/demo/s18.sh          swift test, S18ApprovalSheetUITests, and S15AllTasksUITests
#                                (its session now opens with the sheet up: the S15 x S18 seam)
#   scripts/demo/s18.sh --shots  also refresh the screenshots in evidence/S18/ (1/3 size)
#
# Resources (WORKFLOW.md §6), read from the environment:
#   DSHM_SIM dshm-S18   DSHM_DD (DerivedData) /tmp/dshm-s18-dd
# The bridge and web ports (47814, 3287) are not used: the hosts are in-process fakes.
# The S4 x S18 seam (S4ApprovalUITests close the sheet) needs real DSH: scripts/demo/s4.sh.
# Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0
for a in "$@"; do case "$a" in --shots) SHOTS=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
export DSHM_SIM="${DSHM_SIM:-dshm-S18}" DSHM_DD="${DSHM_DD:-/tmp/dshm-s18-dd}"
NODE24="$HOME/.nvm/versions/node/v24.14.0/bin"
[ -d "$NODE24" ] && export PATH="$NODE24:$PATH"
step() { printf '\n== %s\n' "$*"; }
SIM="$DSHM_SIM"
source scripts/demo/lib.sh
LOGS=/tmp/dshm-s18; mkdir -p "$LOGS"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
export DEST

step "DSHKit tests (swift test, FakeBridge)"
# demo_part (lib.sh): with DSHM_RESUME=1 or on a retry in scripts/review, a part that passed for
# the same code does not run again.
demo_part s18-swift-test bash -c 'source scripts/demo/lib.sh; demo_swift_tests "$1"' _ "$LOGS/swift-test.log"

SHOT_DIR="$(mktemp -d)"
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR"

step "build the app and UI tests ($SIM)"
xcodebuild build-for-testing -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DSHM_DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  > "$LOGS/build.log" 2>&1 || { grep -E "error:" "$LOGS/build.log"; exit 1; }

ui_part() {
  local name=$1 log=$2; shift 2
  demo_part "$name" bash -c '
    log=$1; shift
    xcodebuild test-without-building -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
      -derivedDataPath "$DSHM_DD" -parallel-testing-enabled NO "$@" > "$log" 2>&1 \
      || { grep -E "error:|Test Case.*(passed|failed)" "$log"; exit 1; }
    grep -E "Test Case.*(passed|failed|skipped)" "$log"
    source scripts/demo/lib.sh; demo_no_skipped_ui "$log"' _ "$log" "$@"
}

step "UI: the approval sheet (S18)"
ui_part s18-ui "$LOGS/ui.log" -only-testing:dsh-mobileUITests/S18ApprovalSheetUITests

step "UI: 所有任务 (S15), whose session now opens with the sheet up"
ui_part s18-seam-ui "$LOGS/ui-seam.log" -only-testing:dsh-mobileUITests/S15AllTasksUITests

if [ $SHOTS = 1 ]; then
  step "screenshots → evidence/S18 (1/3 size)"
  mkdir -p evidence/S18
  for f in "$SHOT_DIR"/s18-*.png; do
    [ -e "$f" ] || { echo "no new shots (the UI part was skipped)"; break; }
    out="evidence/S18/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
step "S18 demo passed"
