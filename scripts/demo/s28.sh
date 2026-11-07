#!/bin/bash
# S28 demo and checks: Markdown tables (PLAN.md §5 S28, screen 04, ARCHITECTURE D79). A GFM table in
# the agent's reply shows as a native table, not as its `| a | b |` source.
#
#   scripts/demo/s28.sh          DSHKit tests (swift test: TranscriptBlocks tables), S28MarkdownTablesUITests
#                                (FakeBridge `coding` scenario), S17TranscriptUITests (FakeBridge), and
#                                S8RichDetailUITests (scripts/demo/s8.sh: a real DSH with a mock model)
#   scripts/demo/s28.sh --shots  also refresh the screenshots in evidence/S28/ (1/3 size)
#   scripts/demo/s28.sh --only-s28  only the S28 UI tests (the red run on the unfixed code)
#   DSHM_RESUME=1               skip the parts that passed for the same code (lib.sh demo_part)
#
# Resources (WORKFLOW.md §6), read from the environment (eval "$(scripts/slice-env S28)"):
#   DSHM_SIM dshm-S28   DSHM_DD (DerivedData) /tmp/dshm-s28-dd
#   DSHM_BRIDGE_PORT 47811, DSHM_WEB_PORT 3284, DSHM_HOME ~/.dshm/home-s28: the S8 part's DSH host.
# Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0 ONLY=0
for a in "$@"; do case "$a" in --shots) SHOTS=1 ;; --only-s28) ONLY=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
export DSHM_SIM="${DSHM_SIM:-dshm-S28}" DSHM_DD="${DSHM_DD:-/tmp/dshm-s28-dd}"
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47811}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3284}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home-s28}"
step() { printf '\n== %s\n' "$*"; }
source scripts/demo/lib.sh
LOGS=/tmp/dshm-s28; mkdir -p "$LOGS"
SIM="$DSHM_SIM"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
SHOT_DIR="$(mktemp -d)"
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR"

if [ $ONLY = 0 ]; then
  step "DSHKit tests (swift test: TranscriptBlocks tables)"
  demo_swift_tests "$LOGS/swift-test.log"
  grep -E "TranscriptTables|Test run with" "$LOGS/swift-test.log" || true
fi

step "build the app and UI tests ($SIM)"
xcodebuild build-for-testing -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DSHM_DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  > "$LOGS/build.log" 2>&1 || { grep -E "error:" "$LOGS/build.log"; exit 1; }

# One part per UI test class (lib.sh demo_part): a failure in one does not run the others again.
ui_part() { # name, then -only-testing selectors
  local name=$1; shift
  local args=() t
  for t in "$@"; do args+=("-only-testing:dsh-mobileUITests/$t"); done
  step "UI: $name (log: $LOGS/ui-$name.log)"
  if demo_part "ui-$name" xcodebuild test-without-building -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile \
      -destination "$DEST" -derivedDataPath "$DSHM_DD" -parallel-testing-enabled NO "${args[@]}" \
      > "$LOGS/ui-$name.log" 2>&1; then
    grep -E "Test Case.*(passed|failed|skipped)" "$LOGS/ui-$name.log" || true
  else
    grep -E "error:|Test Case.*(passed|failed)" "$LOGS/ui-$name.log" || tail -30 "$LOGS/ui-$name.log"
    echo "UI tests failed: $name" >&2
    exit 1
  fi
  demo_no_skipped_ui "$LOGS/ui-$name.log"
}

# Copy the screenshots right after the S28 part, so a failure in a later part does not lose them.
copy_shots() {
  [ $SHOTS = 1 ] || return 0
  step "screenshots → evidence/S28 (1/3 size)"
  mkdir -p evidence/S28
  for f in "$SHOT_DIR"/s28-*.png; do
    [ -f "$f" ] || { echo "no S28 screenshots (a part was skipped with DSHM_RESUME=1?)" >&2; exit 1; }
    out="evidence/S28/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
}

ui_part s28 S28MarkdownTablesUITests
copy_shots
[ $ONLY = 1 ] && { step "S28 UI tests passed"; exit 0; }
# The same transcript view, with S17's structured rows cut into it.
ui_part s17 S17TranscriptUITests
# S8's rich detail (fences, diffs, console, the cached reply offline) against a real DSH.
step "S8 rich detail (scripts/demo/s8.sh, log: $LOGS/s8.log)"
demo_part s8 scripts/demo/s8.sh > "$LOGS/s8.log" 2>&1 || { tail -30 "$LOGS/s8.log"; echo "S8 demo failed" >&2; exit 1; }
grep -E "Test Case.*passed|S8 demo passed" "$LOGS/s8.log" || true

step "S28 demo passed"
