#!/bin/bash
# Follow-up in a finished session (ARCHITECTURE D89, screen 04): demo and checks.
#
#   scripts/demo/followup.sh           bridge tests, swift test, and the real-DSH UI demo: finish a
#                                      task, send a follow-up from its page, see the second reply
#                                      under the first, and DSH has both messages in one session
#   scripts/demo/followup.sh --shots   also refresh the screenshots in evidence/T0/ (1/3 size)
#   DSHM_RESUME=1                      skip the parts that passed for the same code (lib.sh demo_part)
#
# Resources (WORKFLOW.md §6), from the environment (`eval "$(scripts/slice-env <ID>)"`):
#   DSHM_BRIDGE_PORT, DSHM_WEB_PORT, DSHM_HOME, DSHM_SIM, DSHM_DD (DerivedData).
# The real part runs scripts/demo/followup-host.mjs: DSH Web with the bridge plugin and DSH's mock
# LLM, in a fresh DSH home under DSHM_HOME. Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0; PART=""
while [ $# -gt 0 ]; do
  case "$1" in
    --shots) SHOTS=1 ;;
    --part) PART="$2"; shift ;;
    *) echo "usage: $0 [--shots]" >&2; exit 2 ;;
  esac
  shift
done
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47810}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3283}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home-followup}" DSHM_SIM="${DSHM_SIM:-dshm-T0}"
export DSHM_DD="${DSHM_DD:-/tmp/dshm-followup-dd}"
export PATH="$HOME/.dshm/bin:$HOME/.nvm/versions/node/v24.14.0/bin:$PATH"
step() { printf '\n== %s\n' "$*"; }
SIM="$DSHM_SIM"
source scripts/demo/lib.sh
LOGS="/tmp/dshm-followup-${DSHM_SIM}"; mkdir -p "$LOGS" "$DSHM_HOME"
export DSHM_FOLLOWUP_SHOTS="${DSHM_FOLLOWUP_SHOTS:-$LOGS/shots}"; mkdir -p "$DSHM_FOLLOWUP_SHOTS"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
export TEST_RUNNER_DSHM_SHOT_DIR="$DSHM_FOLLOWUP_SHOTS"
REAL=dsh-mobileUITests/FollowUpUITests/testFollowUpInAFinishedSessionAgainstRealDSH

case "$PART" in
  ui-real)
    step "UI: a follow-up in a finished session (real DSH Web + bridge, mock LLM)"
    for port in "$DSHM_BRIDGE_PORT" "$DSHM_WEB_PORT"; do
      ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null || { echo "followup: port $port is busy" >&2; exit 1; }
    done
    (cd bridge && corepack pnpm build >/dev/null)
    export DSHM_HOME="$(mktemp -d "$DSHM_HOME/run.XXXXXX")"
    export DSHM_FOLLOWUP_SIGNALS="$(mktemp -d)"
    export TEST_RUNNER_DSHM_FOLLOWUP_SIGNALS="$DSHM_FOLLOWUP_SIGNALS"
    node scripts/demo/followup-host.mjs > "$LOGS/host.log" 2>&1 &
    host_pid=$!
    cleanup() { kill "$host_pid" 2>/dev/null || true; wait "$host_pid" 2>/dev/null || true; rm -rf "$DSHM_HOME" "$DSHM_FOLLOWUP_SIGNALS"; }
    trap cleanup EXIT
    for _ in $(seq 1 360); do
      [ -e "$DSHM_FOLLOWUP_SIGNALS/bridge-port" ] && break
      kill -0 "$host_pid" 2>/dev/null || { cat "$LOGS/host.log"; exit 1; }
      sleep 0.5
    done
    [ -e "$DSHM_FOLLOWUP_SIGNALS/bridge-port" ] || { cat "$LOGS/host.log"; exit 1; }
    xcodebuild test-without-building -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
      -derivedDataPath "$DSHM_DD" -parallel-testing-enabled NO -only-testing:"$REAL" > "$LOGS/ui-real.log" 2>&1 \
      || { grep -E "error:|Test Case.*(passed|failed)" "$LOGS/ui-real.log"; cat "$LOGS/host.log"; exit 1; }
    grep -E "Test Case.*(passed|failed|skipped)" "$LOGS/ui-real.log"
    demo_no_skipped_ui "$LOGS/ui-real.log"
    wait "$host_pid" || { cat "$LOGS/host.log"; exit 1; }
    cat "$LOGS/host.log"
    exit 0 ;;
  "") ;;
  *) echo "unknown part $PART" >&2; exit 2 ;;
esac

demo_prepare_bridge
step "bridge tests (node:test, FakeDSH, golden fixtures; FollowUpAgainstFakeDSH)"
demo_bridge_tests "$LOGS/bridge-test.log"
step "DSHKit tests (swift test, FakeBridge, golden fixtures; FollowUpTests)"
demo_swift_tests "$LOGS/swift-test.log"

step "build the app and UI tests ($SIM)"
xcodebuild build-for-testing -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DSHM_DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  > "$LOGS/build.log" 2>&1 || { grep -E "error:" "$LOGS/build.log"; exit 1; }

rm -f "$DSHM_FOLLOWUP_SHOTS"/*.png
demo_part followup-ui-real "$0" --part ui-real

if [ $SHOTS = 1 ]; then
  step "screenshots → evidence/T0 (1/3 size)"
  mkdir -p evidence/T0
  for f in "$DSHM_FOLLOWUP_SHOTS"/followup-*.png; do
    out="evidence/T0/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
step "follow-up demo passed"
