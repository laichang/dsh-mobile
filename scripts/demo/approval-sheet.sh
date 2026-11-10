#!/bin/bash
# Demo and checks: the approval sheet in a session (design screen 05).
# Re-runnable evidence for its checks. FakeBridge only: two in-process hosts; Home Mac
# starts with a task that waits on `rm -rf ~/Desktop/Q3/tmp` (`-DSHMFakeBridge approvals`), and a
# new task asks for the same command (`-DSHMFakeAsk`). The Web's answer is a Darwin notification
# to the fake hosts. No DSH and no port is needed.
#
#   scripts/demo/approval-sheet.sh          swift test, ApprovalSheetUITests, and AllTasksUITests
#                                (its session now opens with the sheet up: the 所有任务 seam)
#   scripts/demo/approval-sheet.sh --shots  also refresh the screenshots in evidence/approval-sheet/ (1/3 size)
#
# Resources, read from the environment (scripts/slice-env):
#   DSHM_SIM dshm-approval-sheet   DSHM_DD (DerivedData) /tmp/dshm-approval-sheet-dd
# The bridge and web ports (47814, 3287) are not used: the hosts are in-process fakes.
# The approvals seam (ApprovalUITests close the sheet) needs real DSH: scripts/demo/approvals.sh.
# Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0
for a in "$@"; do case "$a" in --shots) SHOTS=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
export DSHM_SIM="${DSHM_SIM:-dshm-approval-sheet}" DSHM_DD="${DSHM_DD:-/tmp/dshm-approval-sheet-dd}"
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
demo_part approval-sheet-swift-test bash -c 'source scripts/demo/lib.sh; demo_swift_tests "$1"' _ "$LOGS/swift-test.log"

SHOT_DIR="$(mktemp -d)"
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR"

step "build the app and UI tests ($SIM)"
scripts/xc build-for-testing -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DSHM_DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  --log "$LOGS/build.log" || { grep -E "error:" "$LOGS/build.log"; exit 1; }

ui_part() {
  local name=$1 log=$2; shift 2
  demo_part "$name" bash -c '
    log=$1; shift
    scripts/xc test-without-building -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
      -derivedDataPath "$DSHM_DD" -parallel-testing-enabled NO "$@" --log "$log" \
      || { grep -E "error:|Test Case.*(passed|failed)" "$log"; exit 1; }
    grep -E "Test Case.*(passed|failed|skipped)" "$log"
    source scripts/demo/lib.sh; demo_no_skipped_ui "$log"' _ "$log" "$@"
}

step "UI: the approval sheet"
ui_part approval-sheet-ui "$LOGS/ui.log" -only-testing:dsh-mobileUITests/ApprovalSheetUITests

step "UI: 所有任务, whose session now opens with the sheet up"
ui_part approval-sheet-seam-ui "$LOGS/ui-seam.log" -only-testing:dsh-mobileUITests/AllTasksUITests

if [ $SHOTS = 1 ]; then
  step "screenshots → ${DSHM_EVIDENCE:-evidence/approval-sheet} (1/3 size)"
  mkdir -p ${DSHM_EVIDENCE:-evidence/approval-sheet}
  for f in "$SHOT_DIR"/approval-sheet-*.png; do
    [ -e "$f" ] || { echo "no new shots (the UI part was skipped)"; break; }
    out="${DSHM_EVIDENCE:-evidence/approval-sheet}/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
step "approval-sheet demo passed"
