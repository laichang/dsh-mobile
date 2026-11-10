#!/bin/bash
# S19 demo and checks: done and failed (screens 06 and X1). Re-runnable evidence
# for S19's Done when items. Everything runs against the in-process FakeBridge; no DSH is needed.
#
#   scripts/demo/s19.sh          swift test (with the FakeBridge outcomes scenario), S19OutcomesUITests,
#                                and S16SessionPageUITests (the seam: the same session page)
#   scripts/demo/s19.sh --shots  also refresh the screenshots in evidence/S19/ (1/3 size)
#   DSHM_RESUME=1               skip the parts that passed for the same code (lib.sh demo_part)
#
# Resources (WORKFLOW.md §6), read from the environment:
#   DSHM_SIM dshm-S19   DSHM_DD (DerivedData) /tmp/dshm-s19-dd
#   (DSHM_BRIDGE_PORT 47817, DSHM_WEB_PORT 3290, DSHM_HOME ~/.dshm/home-s19 are S19's, unused here.)
# Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0
for a in "$@"; do case "$a" in --shots) SHOTS=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
export DSHM_SIM="${DSHM_SIM:-dshm-S19}" DSHM_DD="${DSHM_DD:-/tmp/dshm-s19-dd}"
step() { printf '\n== %s\n' "$*"; }
source scripts/demo/lib.sh
LOGS=/tmp/dshm-s19; mkdir -p "$LOGS"
SIM="$DSHM_SIM"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
SHOT_DIR="$(mktemp -d)"
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR"

step "DSHKit tests (swift test, FakeBridge outcomes scenario)"
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

# Copy the screenshots right after the S19 part, so a failure in a later part does not lose them.
copy_shots() {
  [ $SHOTS = 1 ] || return 0
  step "screenshots → evidence/S19 (1/3 size)"
  mkdir -p evidence/S19
  for f in "$SHOT_DIR"/s19-*.png; do
    [ -f "$f" ] || { echo "no S19 screenshots (a part was skipped with DSHM_RESUME=1?)" >&2; exit 1; }
    out="evidence/S19/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
}

ui_part s19 S19OutcomesUITests
copy_shots
# The seam with S16 (this slice lands second): the session page's own tests.
ui_part s16-seam S16SessionPageUITests

step "S19 demo passed"
