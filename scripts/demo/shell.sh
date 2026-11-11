#!/bin/bash
# Demo and checks: the new UI shell.
#
#   scripts/demo/shell.sh          ShellUITests + every FakeBridge UI test of the M1 slices, on the new shell
#   scripts/demo/shell.sh --all    also bridge tests, swift test, and every slice demo (round-trip.sh, pairing.sh … session-visibility.sh),
#                               each with real DSH, one after the other, on the shell's resources
#   DSHM_RESUME=1 with --all   skip the slice demos that passed for the same code (lib.sh demo_part)
#   scripts/demo/shell.sh --shots  also refresh the screenshots in evidence/shell/ (1/3 size)
#
# Resources, read from the environment (scripts/slice-env):
#   DSHM_BRIDGE_PORT 47810   DSHM_WEB_PORT 3283   DSHM_HOME ~/.dshm/home-shell   DSHM_SIM dshm
#   DSHM_DD (DerivedData) /tmp/dshm-shell-dd
#   multi-host needs a second host: DSHM_SECOND_BRIDGE_PORT 47830, DSHM_SECOND_WEB_PORT 3303.
# Several slice demos refresh their own evidence/<slice>/ shots as a side effect. With --all, this
# script needs a clean evidence/ (outside evidence/shell) and puts those files back afterwards, so a
# shell run never changes another demo's evidence. Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
ALL=0; SHOTS=0
for a in "$@"; do case "$a" in --all) ALL=1 ;; --shots) SHOTS=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47810}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3283}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home-shell}" DSHM_SIM="${DSHM_SIM:-dshm-shell}"
export DSHM_DD="${DSHM_DD:-/tmp/dshm-shell-dd}"
export DSHM_SECOND_BRIDGE_PORT="${DSHM_SECOND_BRIDGE_PORT:-47830}" DSHM_SECOND_WEB_PORT="${DSHM_SECOND_WEB_PORT:-3303}"
NODE24="$HOME/.nvm/versions/node/v24.14.0/bin"
[ -d "$NODE24" ] && export PATH="$NODE24:$PATH"
[ -d "$HOME/.dshm/bin" ] && export PATH="$HOME/.dshm/bin:$PATH"
step() { printf '\n== %s\n' "$*"; }
source scripts/demo/lib.sh
LOGS=/tmp/dshm-t1; mkdir -p "$LOGS" "$DSHM_HOME"
SIM="$DSHM_SIM"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi

if [ $ALL = 1 ] && [ -n "$(git status --porcelain -- evidence ':!${DSHM_EVIDENCE:-evidence/shell}')" ]; then
  echo "shell.sh --all: commit or set aside the changes in evidence/ first (other slices' demos rewrite their shots)" >&2
  exit 1
fi

SHOT_DIR="$(mktemp -d)"
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR" TEST_RUNNER_DSHM_BRIDGE_PORT="$DSHM_BRIDGE_PORT"

step "build the app and UI tests ($SIM)"
scripts/xc build-for-testing -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DSHM_DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  --log "$LOGS/build.log" || { grep -E "error:" "$LOGS/build.log"; exit 1; }

step "UI: the shell, and every FakeBridge UI test of the earlier features on the new shell"
scripts/xc test-without-building -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DSHM_DD" -parallel-testing-enabled NO \
  -only-testing:dsh-mobileUITests/ShellUITests \
  -only-testing:dsh-mobileUITests/RoundTripUITests/testDemoWithFakeBridge \
  -only-testing:dsh-mobileUITests/RoundTripUITests/testPresetPromptLaunchArgument \
  -only-testing:dsh-mobileUITests/RoundTripUITests/testPairDeepLinkOpensPairingStub \
  -only-testing:dsh-mobileUITests/DurableListUITests/testOfflineHostIsNamedWithFakeBridge \
  -only-testing:dsh-mobileUITests/DurableListUITests/testCachedMilestonesAfterKillAndReopenWithFakeBridge \
  -only-testing:dsh-mobileUITests/MilestonesUITests/testTodosTickOffOnCardWithFakeBridge \
  -only-testing:dsh-mobileUITests/MilestonesUITests/testTimelineWithFakeBridge \
  -only-testing:dsh-mobileUITests/MilestonesUITests/testNoMilestonesNoCard \
  -only-testing:dsh-mobileUITests/MultiHostUITests \
  --log "$LOGS/ui-fake.log" || { grep -E "error:|Test Case.*(passed|failed)" "$LOGS/ui-fake.log"; exit 1; }
grep -E "Test Case.*(passed|failed|skipped)" "$LOGS/ui-fake.log"
demo_no_skipped_ui "$LOGS/ui-fake.log"

if [ $SHOTS = 1 ]; then
  step "screenshots → ${DSHM_EVIDENCE:-evidence/shell} (1/3 size)"
  mkdir -p ${DSHM_EVIDENCE:-evidence/shell}
  for f in "$SHOT_DIR"/shell-*.png; do
    out="${DSHM_EVIDENCE:-evidence/shell}/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi

if [ $ALL = 1 ]; then
  restore_evidence() { git checkout -q -- evidence ':!${DSHM_EVIDENCE:-evidence/shell}' 2>/dev/null || true; git clean -qfd -- evidence ':!${DSHM_EVIDENCE:-evidence/shell}' || true; }
  trap restore_evidence EXIT
  # Each demo gets its own DSH home under the shell's, and stops its own hosts when it ends.
  for demo in t0 s1 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 s12 s13; do
    step "slice demo: scripts/demo/$demo.sh (log: $LOGS/demo-$demo.log)"
    mkdir -p "$DSHM_HOME/$demo"
    # demo_part (lib.sh): with DSHM_RESUME=1 or on a retry in scripts/review, a demo that passed
    # for the same code is skipped, and its log from that run stays.
    if demo_part "demo-$demo" bash -c 'DSHM_HOME="$1" "scripts/demo/$2.sh" > "$3" 2>&1' _ \
        "$DSHM_HOME/$demo" "$demo" "$LOGS/demo-$demo.log"; then
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
step "shell demo passed"
