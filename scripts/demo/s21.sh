#!/bin/bash
# S21 demo and checks: hosts and control (PLAN.md §5 S21, DESIGN.md screens H, X2, X3).
# Re-runnable evidence for S21's Done when items. FakeBridge only: in-process hosts from
# `FakeHosts` (`-DSHMFakeBridge hosts`, `hosts-one`); the UI test stops and starts them with
# Darwin notifications. No DSH and no port is needed.
#
#   scripts/demo/s21.sh          swift test, S21HostsUITests, and the seams: S2's offline
#                                FakeBridge test (now the all-offline card) and S14's drawer
#                                tests (the "2 / 3" pill now opens the hosts sheet)
#   scripts/demo/s21.sh --shots  also refresh the screenshots in evidence/S21/ (1/3 size)
#
# Resources (WORKFLOW.md §6), read from the environment:
#   DSHM_SIM dshm-S21   DSHM_DD (DerivedData) /tmp/dshm-s21-dd
# The bridge and web ports (47816, 3289) are not used: the hosts are in-process fakes.
# Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0
for a in "$@"; do case "$a" in --shots) SHOTS=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
export DSHM_SIM="${DSHM_SIM:-dshm-S21}" DSHM_DD="${DSHM_DD:-/tmp/dshm-s21-dd}"
NODE24="$HOME/.nvm/versions/node/v24.14.0/bin"
[ -d "$NODE24" ] && export PATH="$NODE24:$PATH"
step() { printf '\n== %s\n' "$*"; }
SIM="$DSHM_SIM"
source scripts/demo/lib.sh
LOGS=/tmp/dshm-s21; mkdir -p "$LOGS"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
export DEST

step "DSHKit tests (swift test, FakeBridge)"
# demo_part (lib.sh): with DSHM_RESUME=1 or on a retry in scripts/review, a part that passed for
# the same code does not run again.
demo_part s21-swift-test bash -c 'source scripts/demo/lib.sh; demo_swift_tests "$1"' _ "$LOGS/swift-test.log"

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

step "UI: hosts sheet, one host, all hosts offline (S21)"
ui_part s21-ui "$LOGS/ui.log" -only-testing:dsh-mobileUITests/S21HostsUITests

step "UI: seams. S2's offline FakeBridge host (the card on 01), S14's drawer (the pill)"
ui_part s21-seam-ui "$LOGS/ui-seam.log" \
  -only-testing:dsh-mobileUITests/S2DurableListUITests/testOfflineHostIsNamedWithFakeBridge \
  -only-testing:dsh-mobileUITests/S14DrawerUITests/testDrawerGroupsByHostAndWorkspaceWithStatusMarks \
  -only-testing:dsh-mobileUITests/S14DrawerUITests/testOfflineHostSessionsOpenFromTheCache

if [ $SHOTS = 1 ]; then
  step "screenshots → evidence/S21 (1/3 size)"
  mkdir -p evidence/S21
  for f in "$SHOT_DIR"/s21-*.png; do
    [ -e "$f" ] || { echo "no new shots (the UI part was skipped)"; break; }
    out="evidence/S21/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
step "S21 demo passed"
