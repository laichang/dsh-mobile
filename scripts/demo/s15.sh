#!/bin/bash
# S15 demo and checks: 所有任务 (PLAN.md §5 S15, DESIGN.md screen 03). Re-runnable evidence for
# S15's Done when items. FakeBridge only: two in-process hosts, each with a task that waits on an
# approval (`-DSHMFakeBridge approvals`); no DSH and no port is needed.
#
#   scripts/demo/s15.sh          swift test, S15AllTasksUITests, and the FakeBridge UI tests of
#                                earlier slices that look at 所有任务 (T1, S2, S3, S9)
#   scripts/demo/s15.sh --shots  also refresh the screenshots in evidence/S15/ (1/3 size)
#
# Resources (WORKFLOW.md §6), read from the environment:
#   DSHM_SIM dshm-S15   DSHM_DD (DerivedData) /tmp/dshm-s15-dd
# The bridge and web ports (47812, 3285) are not used: the hosts are in-process fakes.
# Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0
for a in "$@"; do case "$a" in --shots) SHOTS=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
export DSHM_SIM="${DSHM_SIM:-dshm-S15}" DSHM_DD="${DSHM_DD:-/tmp/dshm-s15-dd}"
NODE24="$HOME/.nvm/versions/node/v24.14.0/bin"
[ -d "$NODE24" ] && export PATH="$NODE24:$PATH"
step() { printf '\n== %s\n' "$*"; }
SIM="$DSHM_SIM"
source scripts/demo/lib.sh
LOGS=/tmp/dshm-s15; mkdir -p "$LOGS"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
export DEST

step "DSHKit tests (swift test, FakeBridge)"
# demo_part (lib.sh): with DSHM_RESUME=1 or on a retry in scripts/review, a part that passed for
# the same code does not run again.
demo_part s15-swift-test bash -c 'source scripts/demo/lib.sh; demo_swift_tests "$1"' _ "$LOGS/swift-test.log"

SHOT_DIR="$(mktemp -d)"
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR"

step "build the app and UI tests ($SIM)"
scripts/xc build-for-testing -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DSHM_DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  --log "$LOGS/build.log" || { grep -E "error:" "$LOGS/build.log"; exit 1; }

step "UI: 所有任务 (S15), and the FakeBridge UI tests of T1, S2, S3, S9 that use it"
UI_TESTS=(
  -only-testing:dsh-mobileUITests/S15AllTasksUITests
  -only-testing:dsh-mobileUITests/T1ShellUITests/testAllTasksAndDrawerOpenSessions
  -only-testing:dsh-mobileUITests/S2DurableListUITests/testOfflineHostIsNamedWithFakeBridge
  -only-testing:dsh-mobileUITests/S2DurableListUITests/testCachedMilestonesAfterKillAndReopenWithFakeBridge
  -only-testing:dsh-mobileUITests/S3MilestonesUITests/testTodosTickOffOnCardWithFakeBridge
  -only-testing:dsh-mobileUITests/S9MultiHostUITests
)
demo_part s15-ui bash -c '
  log=$1; shift
  scripts/xc test-without-building -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
    -derivedDataPath "$DSHM_DD" -parallel-testing-enabled NO "$@" --log "$log" \
    || { grep -E "error:|Test Case.*(passed|failed)" "$log"; exit 1; }
  grep -E "Test Case.*(passed|failed|skipped)" "$log"
  source scripts/demo/lib.sh; demo_no_skipped_ui "$log"' _ "$LOGS/ui.log" "${UI_TESTS[@]}"

if [ $SHOTS = 1 ]; then
  step "screenshots → evidence/S15 (1/3 size)"
  mkdir -p evidence/S15
  for f in "$SHOT_DIR"/s15-*.png; do
    [ -e "$f" ] || { echo "no new shots (the UI part was skipped)"; break; }
    out="evidence/S15/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
step "S15 demo passed"
