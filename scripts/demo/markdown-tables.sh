#!/bin/bash
# Demo and checks: Markdown tables (screen 04). A GFM table in
# the agent's reply shows as a native table, not as its `| a | b |` source.
#
#   scripts/demo/markdown-tables.sh          DSHKit tests (swift test: TranscriptBlocks tables), MarkdownTablesUITests
#                                (FakeBridge `coding` scenario), TranscriptUITests (FakeBridge), and
#                                RichDetailUITests (scripts/demo/rich-detail.sh: a real DSH with a mock model)
#   scripts/demo/markdown-tables.sh --shots  also refresh the screenshots in evidence/markdown-tables/ (1/3 size)
#   scripts/demo/markdown-tables.sh --only-tables  only the Markdown tables UI tests (the red run on the unfixed code)
#   DSHM_RESUME=1               skip the parts that passed for the same code (lib.sh demo_part)
#
# Resources (WORKFLOW.md §6), read from the environment (eval "$(scripts/slice-env <ID>)"):
#   DSHM_SIM dshm-markdown-tables   DSHM_DD (DerivedData) /tmp/dshm-markdown-tables-dd
#   DSHM_BRIDGE_PORT 47811, DSHM_WEB_PORT 3284, DSHM_HOME ~/.dshm/home-markdown-tables: the rich detail part's DSH host.
# Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0 ONLY=0
for a in "$@"; do case "$a" in --shots) SHOTS=1 ;; --only-tables) ONLY=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
export DSHM_SIM="${DSHM_SIM:-dshm-markdown-tables}" DSHM_DD="${DSHM_DD:-/tmp/dshm-markdown-tables-dd}"
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47811}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3284}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home-markdown-tables}"
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

# Copy the screenshots right after the Markdown tables part, so a failure in a later part does not lose them.
copy_shots() {
  [ $SHOTS = 1 ] || return 0
  step "screenshots → ${DSHM_EVIDENCE:-evidence/markdown-tables} (1/3 size)"
  mkdir -p ${DSHM_EVIDENCE:-evidence/markdown-tables}
  for f in "$SHOT_DIR"/markdown-tables-*.png; do
    [ -f "$f" ] || { echo "no Markdown tables screenshots (a part was skipped with DSHM_RESUME=1?)" >&2; exit 1; }
    out="${DSHM_EVIDENCE:-evidence/markdown-tables}/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
}

ui_part s28 MarkdownTablesUITests
copy_shots
[ $ONLY = 1 ] && { step "Markdown tables UI tests passed"; exit 0; }
# The same transcript view, with the transcript's structured rows cut into it.
ui_part s17 TranscriptUITests
# The rich detail (fences, diffs, console, the cached reply offline) against a real DSH.
step "rich detail (scripts/demo/rich-detail.sh, log: $LOGS/rich-detail.log)"
demo_part rich-detail scripts/demo/rich-detail.sh > "$LOGS/rich-detail.log" 2>&1 || { tail -30 "$LOGS/rich-detail.log"; echo "rich detail failed" >&2; exit 1; }
grep -E "Test Case.*passed|rich-detail demo passed" "$LOGS/rich-detail.log" || true

step "markdown-tables demo passed"
