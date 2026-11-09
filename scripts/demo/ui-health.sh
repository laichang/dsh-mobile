#!/bin/bash
# UI test health: the UI tests that once typed before the field had keyboard focus, and the UI
# tests that once waited 60 s per step for the app to idle. One part per test class or test
# (lib.sh demo_part), so a review names the part that needed a retry.
#
#   scripts/demo/ui-health.sh     build, then the parts below
#   DSHM_RESUME=1                 skip the parts that passed for the same code (lib.sh demo_part)
#
# Typing (the shared send/type helpers in UITestSupport.swift wait for keyboard focus):
#   focus-s3  S3MilestonesUITests/testTodosTickOffOnCardWithFakeBridge
#   focus-s2  S2DurableListUITests/testCachedMilestonesAfterKillAndReopenWithFakeBridge
#   focus-t0  T0DemoUITests/testDemoAgainstRealDSH (real DSH + bridge from scripts/dsh-up.mjs)
# Waits for the app to idle (these tests launch the app with UIKit view animations off, ARCHITECTURE D128):
#   idle-s16  S16SessionPageUITests   idle-s15  S15AllTasksUITests
#   idle-s19  S19OutcomesUITests      idle-s20  S20PickersUITests
#
# Each part prints the duration of each test and its longest "Wait for … to idle" step. A part
# fails when a test fails or is skipped, when a step waits $IDLE_LIMIT s (60) or more for the app to
# idle (or XCTest says "animations complete notification not received"), or when
# S16SessionPageUITests/testMilestoneBarStaysAtTopWhileTranscriptScrolls takes $S16_LIMIT s (120)
# or more.
#
# Resources (WORKFLOW.md §6), read from the environment:
#   DSHM_SIM dshm-S9   DSHM_DD (DerivedData) /tmp/dshm-s9-dd   DSHM_BRIDGE_PORT 47810
#   DSHM_WEB_PORT 3283   DSHM_HOME ~/.dshm/home-s9 (the T0 part's DSH)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
PART=""
while [ $# -gt 0 ]; do
  case "$1" in
    --part) PART="$2"; shift ;;
    *) echo "usage: $0" >&2; exit 2 ;;
  esac
  shift
done
export DSHM_SIM="${DSHM_SIM:-dshm-S9}" DSHM_DD="${DSHM_DD:-/tmp/dshm-s9-dd}"
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47810}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3283}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home-s9}"
NODE24="$HOME/.nvm/versions/node/v24.14.0/bin"
[ -d "$NODE24" ] && export PATH="$NODE24:$PATH"
[ -d "$HOME/.dshm/bin" ] && export PATH="$HOME/.dshm/bin:$PATH"
step() { printf '\n== %s\n' "$*"; }
source scripts/demo/lib.sh
LOGS="/tmp/dshm-ui-health-$DSHM_SIM"; mkdir -p "$LOGS"
SIM="$DSHM_SIM"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
IDLE_LIMIT=60
S16_LIMIT=120
S16_SCROLL=S16SessionPageUITests/testMilestoneBarStaysAtTopWhileTranscriptScrolls

# Per test in LOG: the duration and the longest wait for the app to idle. A wait is the time from
# its "Wait for … to idle" line to the next timed line (or to the end of the test). Fails on a
# wait of IDLE_LIMIT s or more, on XCTest's "animations complete notification not received", and
# on a test that takes longer than its limit (args: Suite/name=seconds).
ui_waits() {
  local log=$1; shift
  awk -v idle="$IDLE_LIMIT" -v limits="$*" '
    BEGIN { n = split(limits, l, " "); for (i = 1; i <= n; i++) { split(l[i], kv, "="); lim[kv[1]] = kv[2] } }
    function close_wait(t) { if (wt != "" && t - wt > longest) longest = t - wt; wt = "" }
    /^Test Case .* started/ { longest = 0; wt = ""; stuck = 0; next }
    /^ *t = *[0-9.]+s/ {
      t = $0; sub(/^ *t = */, "", t); sub(/s.*/, "", t); t += 0
      close_wait(t)
      if ($0 ~ /Wait for .* to idle/) wt = t
      if ($0 ~ /animations complete notification not received/) stuck++
      next
    }
    /^Test Case .* (passed|failed) \(/ {
      name = $0; sub(/^Test Case .-\[[A-Za-z_]+\./, "", name); sub(/\].*/, "", name); sub(/ /, "/", name)
      d = $0; sub(/.*\(/, "", d); sub(/ seconds.*/, "", d); d += 0
      close_wait(d)
      verdict = ($0 ~ / failed \(/) ? "; the test failed" : ""
      if (longest >= idle) verdict = verdict sprintf("; a step waited %.0f s for the app to idle (limit %d s)", longest, idle)
      if (stuck) verdict = verdict sprintf("; %d \"animations complete notification not received\"", stuck)
      if ((name in lim) && d >= lim[name]) verdict = verdict sprintf("; took %.0f s (limit %d s)", d, lim[name])
      printf "  %-90s %7.1f s   longest idle wait %5.1f s%s\n", name, d, longest, (verdict == "" ? "" : "   FAIL" verdict)
      if (verdict != "") bad = 1
    }
    END { exit bad }' "$log"
}

ui_test() { # part name, then Suite or Suite/test selectors
  local name=$1; shift
  local args=() t log="$LOGS/ui-$name.log"
  for t in "$@"; do args+=("-only-testing:dsh-mobileUITests/$t"); done
  step "UI: $name ($*) (log: $log)"
  # A new install of the app over the old one can race with a launch by liveactivitiesd (a Live
  # Activity left by an earlier run): the first test then got an app without its launch arguments
  # (ARCHITECTURE D129). Remove the app first; xcodebuild installs it again.
  xcrun simctl uninstall "$SIM" chang.dsh-mobile >/dev/null 2>&1 || true
  if ! xcodebuild test-without-building -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
      -derivedDataPath "$DSHM_DD" -parallel-testing-enabled NO "${args[@]}" > "$log" 2>&1; then
    grep -E "error:|Test Case.*(passed|failed)" "$log" || tail -30 "$log"
    ui_waits "$log" "$S16_SCROLL=$S16_LIMIT" || true
    echo "UI tests failed: $name" >&2
    return 1
  fi
  # The pass lines go to stdout too: scripts/review looks for its test: pointers there.
  grep -E "Test Case.*(passed|failed|skipped)" "$log"
  demo_no_skipped_ui "$log"
  step "durations and idle waits: $name"
  ui_waits "$log" "$S16_SCROLL=$S16_LIMIT" || { echo "UI tests too slow or not idle: $name" >&2; return 1; }
}

case "$PART" in
  focus-s3) ui_test focus-s3 S3MilestonesUITests/testTodosTickOffOnCardWithFakeBridge; exit ;;
  focus-s2) ui_test focus-s2 S2DurableListUITests/testCachedMilestonesAfterKillAndReopenWithFakeBridge; exit ;;
  focus-t0)
    DSH_PID=""
    cleanup() { [ -n "$DSH_PID" ] && kill "$DSH_PID" 2>/dev/null || true; }
    trap cleanup EXIT
    if ! lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
      step "starting real DSH + bridge on $DSHM_BRIDGE_PORT (scripts/dsh-up.mjs, DSH_HOME $DSHM_HOME)"
      (cd bridge && corepack pnpm build >/dev/null)
      node scripts/dsh-up.mjs > "$LOGS/dsh-up.log" 2>&1 &
      DSH_PID=$!
      for _ in $(seq 1 240); do lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.5; done
      lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null || { cat "$LOGS/dsh-up.log"; echo "bridge did not come up" >&2; exit 1; }
    fi
    export TEST_RUNNER_DSHM_REAL_DSH=1 TEST_RUNNER_DSHM_BRIDGE_PORT="$DSHM_BRIDGE_PORT"
    ui_test focus-t0 T0DemoUITests/testDemoAgainstRealDSH; exit ;;
  idle-s16) ui_test idle-s16 S16SessionPageUITests; exit ;;
  idle-s15) ui_test idle-s15 S15AllTasksUITests; exit ;;
  idle-s19) ui_test idle-s19 S19OutcomesUITests; exit ;;
  idle-s20) ui_test idle-s20 S20PickersUITests; exit ;;
  "") ;;
  *) echo "unknown part $PART" >&2; exit 2 ;;
esac

step "bridge dependencies (pnpm install --frozen-lockfile)"
(cd bridge && corepack pnpm install --frozen-lockfile >/dev/null)

step "build the app and UI tests ($SIM)"
xcodebuild build-for-testing -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DSHM_DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  > "$LOGS/build.log" 2>&1 || { grep -E "error:" "$LOGS/build.log"; exit 1; }

STATUS=0
for part in focus-s3 focus-s2 focus-t0 idle-s16 idle-s15 idle-s19 idle-s20; do
  demo_part "ui-health-$part" "$0" --part "$part" || STATUS=1
done
[ $STATUS = 0 ] || { echo "ui-health: a part failed" >&2; exit 1; }
step "UI health passed"
