#!/bin/bash
# T1 demo and checks: the new UI shell (PLAN.md §5 T1). Re-runnable evidence for T1's Done when items.
#
#   scripts/demo/t1.sh          T1ShellUITests + every FakeBridge UI test of the M1 slices, on the new shell
#   scripts/demo/t1.sh --all    also bridge tests, swift test, and every slice demo (t0.sh, s1.sh … s13.sh),
#                               each with real DSH, one after the other, on T1's resources
#   scripts/demo/t1.sh --shots  also refresh the screenshots in evidence/T1/ (1/3 size)
#
# Resources (WORKFLOW.md §6), read from the environment:
#   DSHM_BRIDGE_PORT 47810   DSHM_WEB_PORT 3283   DSHM_HOME ~/.dshm/home-t1   DSHM_SIM dshm-T1
#   DSHM_DD (DerivedData) /tmp/dshm-t1-dd
#   S9 needs a second host: DSHM_SECOND_BRIDGE_PORT 47830, DSHM_SECOND_WEB_PORT 3303.
# Several slice demos refresh their own evidence/<slice>/ shots as a side effect. With --all, this
# script needs a clean evidence/ (outside evidence/T1) and puts those files back afterwards, so a
# T1 run never changes another slice's evidence. Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
ALL=0; SHOTS=0
for a in "$@"; do case "$a" in --all) ALL=1 ;; --shots) SHOTS=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47810}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3283}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home-t1}" DSHM_SIM="${DSHM_SIM:-dshm-T1}"
export DSHM_DD="${DSHM_DD:-/tmp/dshm-t1-dd}"
export DSHM_SECOND_BRIDGE_PORT="${DSHM_SECOND_BRIDGE_PORT:-47830}" DSHM_SECOND_WEB_PORT="${DSHM_SECOND_WEB_PORT:-3303}"
NODE24="$HOME/.nvm/versions/node/v24.14.0/bin"
[ -d "$NODE24" ] && export PATH="$NODE24:$PATH"
[ -d "$HOME/.dshm/bin" ] && export PATH="$HOME/.dshm/bin:$PATH"
step() { printf '\n== %s\n' "$*"; }
source scripts/demo/lib.sh
LOGS=/tmp/dshm-t1; mkdir -p "$LOGS" "$DSHM_HOME"
SIM="$DSHM_SIM"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi

if [ $ALL = 1 ] && [ -n "$(git status --porcelain -- evidence ':!evidence/T1')" ]; then
  echo "t1.sh --all: commit or set aside the changes in evidence/ first (other slices' demos rewrite their shots)" >&2
  exit 1
fi

SHOT_DIR="$(mktemp -d)"
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR" TEST_RUNNER_DSHM_BRIDGE_PORT="$DSHM_BRIDGE_PORT"

step "build the app and UI tests ($SIM)"
xcodebuild build-for-testing -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DSHM_DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  > "$LOGS/build.log" 2>&1 || { grep -E "error:" "$LOGS/build.log"; exit 1; }

step "UI: T1 shell, and every FakeBridge UI test of T0–S13 on the new shell"
xcodebuild test-without-building -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DSHM_DD" -parallel-testing-enabled NO \
  -only-testing:dsh-mobileUITests/T1ShellUITests \
  -only-testing:dsh-mobileUITests/T0DemoUITests/testDemoWithFakeBridge \
  -only-testing:dsh-mobileUITests/T0DemoUITests/testPresetPromptLaunchArgument \
  -only-testing:dsh-mobileUITests/T0DemoUITests/testPairDeepLinkOpensPairingStub \
  -only-testing:dsh-mobileUITests/S2DurableListUITests/testOfflineHostIsNamedWithFakeBridge \
  -only-testing:dsh-mobileUITests/S2DurableListUITests/testCachedMilestonesAfterKillAndReopenWithFakeBridge \
  -only-testing:dsh-mobileUITests/S3MilestonesUITests/testTodosTickOffOnCardWithFakeBridge \
  -only-testing:dsh-mobileUITests/S3MilestonesUITests/testTimelineWithFakeBridge \
  -only-testing:dsh-mobileUITests/S3MilestonesUITests/testNoMilestonesNoCard \
  -only-testing:dsh-mobileUITests/S9MultiHostUITests \
  > "$LOGS/ui-fake.log" 2>&1 || { grep -E "error:|Test Case.*(passed|failed)" "$LOGS/ui-fake.log"; exit 1; }
grep -E "Test Case.*(passed|failed|skipped)" "$LOGS/ui-fake.log"
demo_no_skipped_ui "$LOGS/ui-fake.log"

if [ $SHOTS = 1 ]; then
  step "screenshots → evidence/T1 (1/3 size)"
  mkdir -p evidence/T1
  for f in "$SHOT_DIR"/t1-*.png; do
    out="evidence/T1/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi

if [ $ALL = 1 ]; then
  restore_evidence() { git checkout -q -- evidence ':!evidence/T1' 2>/dev/null || true; git clean -qfd -- evidence ':!evidence/T1' || true; }
  trap restore_evidence EXIT
  # Each slice demo gets its own DSH home under T1's, and stops its own hosts when it ends.
  for demo in t0 s1 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 s12 s13; do
    step "slice demo: scripts/demo/$demo.sh (log: $LOGS/demo-$demo.log)"
    mkdir -p "$DSHM_HOME/$demo"
    if DSHM_HOME="$DSHM_HOME/$demo" "scripts/demo/$demo.sh" > "$LOGS/demo-$demo.log" 2>&1; then
      grep -E "Test Case.*(passed|failed|skipped)" "$LOGS/demo-$demo.log" || true
    else
      tail -30 "$LOGS/demo-$demo.log"
      echo "scripts/demo/$demo.sh failed" >&2
      exit 1
    fi
    if grep -qE "Test Case.*skipped" "$LOGS/demo-$demo.log"; then
      grep -E "Test Case.*skipped" "$LOGS/demo-$demo.log"; echo "$demo.sh skipped a UI test" >&2; exit 1
    fi
  done
fi
step "T1 demo passed"
