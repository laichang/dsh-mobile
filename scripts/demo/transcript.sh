#!/bin/bash
# Demo and checks: the structured transcript (screen 04). Re-runnable evidence
# Re-runnable evidence for its checks. The UI runs against the in-process FakeBridge; no DSH is needed.
#
#   scripts/demo/transcript.sh          codegen check, bridge tests (FakeDSH, transcript fixtures),
#                                swift test (FakeBridge transcript task, fixtures), TranscriptUITests,
#                                and the session page tests on the same page
#   scripts/demo/transcript.sh --shots  also refresh the screenshots in evidence/transcript/ (1/3 size)
#   DSHM_RESUME=1               skip the parts that passed for the same code (lib.sh demo_part)
#
# Resources, read from the environment (scripts/slice-env):
#   DSHM_SIM dshm-transcript   DSHM_DD (DerivedData) /tmp/dshm-transcript-dd
#   (DSHM_BRIDGE_PORT 47818, DSHM_WEB_PORT 3291, DSHM_HOME ~/.dshm/home-transcript are unused here.)
# Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0
for a in "$@"; do case "$a" in --shots) SHOTS=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
export DSHM_SIM="${DSHM_SIM:-dshm-transcript}" DSHM_DD="${DSHM_DD:-/tmp/dshm-transcript-dd}"
NODE24="$HOME/.nvm/versions/node/v24.14.0/bin"
[ -d "$NODE24" ] && export PATH="$NODE24:$PATH"
step() { printf '\n== %s\n' "$*"; }
source scripts/demo/lib.sh
LOGS=/tmp/dshm-s17; mkdir -p "$LOGS"
SIM="$DSHM_SIM"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
SHOT_DIR="$(mktemp -d)"
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR"

demo_prepare_bridge

step "bridge tests (node:test, FakeDSH, transcript fixtures)"
demo_bridge_tests "$LOGS/bridge-test.log"
grep -E "TranscriptMapperAgainstFakeDSH|TranscriptFixtures|mapsThinkingAndToolEventsIntoBlocks|thinkingAndToolBlocksDecode" \
  "$LOGS/bridge-test.log" || true

step "DSHKit tests (swift test, FakeBridge transcript task, golden fixtures)"
demo_swift_tests "$LOGS/swift-test.log"

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

# Copy the screenshots right after the transcript part, so a failure in a later part does not lose them.
copy_shots() {
  [ $SHOTS = 1 ] || return 0
  step "screenshots → ${DSHM_EVIDENCE:-evidence/transcript} (1/3 size)"
  mkdir -p ${DSHM_EVIDENCE:-evidence/transcript}
  for f in "$SHOT_DIR"/transcript-*.png; do
    [ -f "$f" ] || { echo "no transcript screenshots (a part was skipped with DSHM_RESUME=1?)" >&2; exit 1; }
    out="${DSHM_EVIDENCE:-evidence/transcript}/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
}

ui_part s17 TranscriptUITests
copy_shots
# The page the transcript adds its rows to: its layout and its stop key still work.
ui_part s16 SessionPageUITests

step "transcript demo passed"
