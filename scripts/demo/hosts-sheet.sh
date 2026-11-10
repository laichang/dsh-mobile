#!/bin/bash
# Demo and checks: hosts and control (design screen H, X2, X3).
# Re-runnable evidence for its checks. FakeBridge only: in-process hosts from
# `FakeHosts` (`-DSHMFakeBridge hosts`, `hosts-one`); the UI test stops and starts them with
# Darwin notifications. No DSH and no port is needed.
#
#   scripts/demo/hosts-sheet.sh          swift test, HostsUITests, and the seams: the durable list's offline
#                                FakeBridge test (now the all-offline card) and the drawer
#                                tests (the "2 / 3" pill now opens the hosts sheet)
#   scripts/demo/hosts-sheet.sh --shots  also refresh the screenshots in evidence/hosts-sheet/ (1/3 size)
#
# Resources (WORKFLOW.md §6), read from the environment:
#   DSHM_SIM dshm-hosts-sheet   DSHM_DD (DerivedData) /tmp/dshm-hosts-sheet-dd
# The bridge and web ports (47816, 3289) are not used: the hosts are in-process fakes.
# Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0
for a in "$@"; do case "$a" in --shots) SHOTS=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
export DSHM_SIM="${DSHM_SIM:-dshm-hosts-sheet}" DSHM_DD="${DSHM_DD:-/tmp/dshm-hosts-sheet-dd}"
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
demo_part hosts-sheet-swift-test bash -c 'source scripts/demo/lib.sh; demo_swift_tests "$1"' _ "$LOGS/swift-test.log"

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

step "UI: hosts sheet, one host, all hosts offline"
ui_part hosts-sheet-ui "$LOGS/ui.log" -only-testing:dsh-mobileUITests/HostsUITests

step "UI: seams. the durable list's offline FakeBridge host (the card on 01), the drawer (the pill)"
ui_part hosts-sheet-seam-ui "$LOGS/ui-seam.log" \
  -only-testing:dsh-mobileUITests/DurableListUITests/testOfflineHostIsNamedWithFakeBridge \
  -only-testing:dsh-mobileUITests/DrawerUITests/testDrawerGroupsByHostAndWorkspaceWithStatusMarks \
  -only-testing:dsh-mobileUITests/DrawerUITests/testOfflineHostSessionsOpenFromTheCache

if [ $SHOTS = 1 ]; then
  step "screenshots → ${DSHM_EVIDENCE:-evidence/hosts-sheet} (1/3 size)"
  mkdir -p ${DSHM_EVIDENCE:-evidence/hosts-sheet}
  for f in "$SHOT_DIR"/hosts-sheet-*.png; do
    [ -e "$f" ] || { echo "no new shots (the UI part was skipped)"; break; }
    out="${DSHM_EVIDENCE:-evidence/hosts-sheet}/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
step "hosts-sheet demo passed"
