#!/bin/bash
# Follow-ups in a session (screen 04, X1): demo and checks.
#
#   scripts/demo/followup.sh           bridge tests, swift test, and the real-DSH UI demo: finish a
#                                      task, send a follow-up from its page, see the second reply
#                                      under the first, and DSH has both messages in one session
#   scripts/demo/followup.sh --running the same tests, and the real-DSH UI demo while a task runs:
#                                      queue two follow-ups, send one now (the agent takes it at its
#                                      next step, the stop key stays), the other runs as the next
#                                      turn; then stop a task and continue it with a new message
#   scripts/demo/followup.sh --steer   the same tests, and the real-DSH UI demo of 立即发送 while the
#                                      agent is in a long tool step (scripts/demo/steer-host.mjs):
#                                      the message goes into the transcript when the step ends, and
#                                      nothing floats above the field after the turn
#   --shots                            also refresh the screenshots in evidence/ (1/3 size)
#   DSHM_RESUME=1                      skip the parts that passed for the same code (lib.sh demo_part)
#
# Resources, from the environment (`eval "$(scripts/slice-env <ID>)"`):
#   DSHM_BRIDGE_PORT, DSHM_WEB_PORT, DSHM_HOME, DSHM_SIM, DSHM_DD (DerivedData).
# The real part runs scripts/demo/followup-host.mjs: DSH Web with the bridge plugin and DSH's mock
# LLM, in a fresh DSH home under DSHM_HOME. Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0; PART=""; RUNNING=0; STEER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --shots) SHOTS=1 ;;
    --running) RUNNING=1 ;;
    --steer) STEER=1 ;;
    --part) PART="$2"; shift ;;
    *) echo "usage: $0 [--running] [--steer] [--shots]" >&2; exit 2 ;;
  esac
  shift
done
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47810}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3283}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home-followup}" DSHM_SIM="${DSHM_SIM:-dshm-followup}"
export DSHM_DD="${DSHM_DD:-/tmp/dshm-followup-dd}"
export PATH="$HOME/.dshm/bin:$HOME/.nvm/versions/node/v24.14.0/bin:$PATH"
step() { printf '\n== %s\n' "$*"; }
SIM="$DSHM_SIM"
source scripts/demo/lib.sh
demo_tls_home
LOGS="/tmp/dshm-followup-${DSHM_SIM}"; mkdir -p "$LOGS" "$DSHM_HOME"
export DSHM_FOLLOWUP_SHOTS="${DSHM_FOLLOWUP_SHOTS:-$LOGS/shots}"; mkdir -p "$DSHM_FOLLOWUP_SHOTS"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
export TEST_RUNNER_DSHM_SHOT_DIR="$DSHM_FOLLOWUP_SHOTS"
REAL=dsh-mobileUITests/FollowUpUITests/testFollowUpInAFinishedSessionAgainstRealDSH
QUEUE=dsh-mobileUITests/FollowUpQueueUITests

# One UI part against real DSH: the host in the background, then the tests. $1: the log; then the
# -only-testing arguments.
ui_against_real_dsh() {
  local log=$1; shift
  for port in "$DSHM_BRIDGE_PORT" "$DSHM_WEB_PORT"; do
    ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null || { echo "followup: port $port is busy" >&2; exit 1; }
  done
  (cd bridge && corepack pnpm build >/dev/null)
  export DSHM_HOME="$(mktemp -d "$DSHM_HOME/run.XXXXXX")"
  export DSHM_FOLLOWUP_SIGNALS="$(mktemp -d)"
  export TEST_RUNNER_DSHM_FOLLOWUP_SIGNALS="$DSHM_FOLLOWUP_SIGNALS"
  node "${DSHM_FOLLOWUP_HOST:-scripts/demo/followup-host.mjs}" > "$LOGS/host.log" 2>&1 &
  host_pid=$!
  cleanup() { kill "$host_pid" 2>/dev/null || true; wait "$host_pid" 2>/dev/null || true; rm -rf "$DSHM_HOME" "$DSHM_FOLLOWUP_SIGNALS"; }
  trap cleanup EXIT
  for _ in $(seq 1 360); do
    [ -e "$DSHM_FOLLOWUP_SIGNALS/bridge-port" ] && break
    kill -0 "$host_pid" 2>/dev/null || { cat "$LOGS/host.log"; exit 1; }
    sleep 0.5
  done
  [ -e "$DSHM_FOLLOWUP_SIGNALS/bridge-port" ] || { cat "$LOGS/host.log"; exit 1; }
  demo_tls_ui test-without-building -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
    -derivedDataPath "$DSHM_DD" -parallel-testing-enabled NO "$@" --log "$log" \
    || { grep -E "error:|Test Case.*(passed|failed)" "$log"; cat "$LOGS/host.log"; exit 1; }
  grep -E "Test Case.*(passed|failed|skipped)" "$log"
  demo_no_skipped_ui "$log"
  wait "$host_pid" || { cat "$LOGS/host.log"; exit 1; }
  cat "$LOGS/host.log"
}

case "$PART" in
  ui-real)
    step "UI: a follow-up in a finished session (real DSH Web + bridge, mock LLM)"
    ui_against_real_dsh "$LOGS/ui-real.log" -only-testing:"$REAL"
    exit 0 ;;
  ui-running)
    step "UI: follow-ups while a task runs, and after a stop (real DSH Web + bridge, slow mock LLM)"
    export DSHM_FOLLOWUP_MODE=running
    ui_against_real_dsh "$LOGS/ui-running.log" \
      -only-testing:"$QUEUE/testFollowUpsWhileATaskRunsAgainstRealDSH" \
      -only-testing:"$QUEUE/testContinueAfterAnInterruptAgainstRealDSH"
    exit 0 ;;
  ui-steer)
    step "UI: 立即发送 while the agent is in a long tool step (real DSH Web + bridge, scripted mock LLM)"
    export DSHM_FOLLOWUP_HOST=scripts/demo/steer-host.mjs
    ui_against_real_dsh "$LOGS/ui-steer.log" -only-testing:"$QUEUE/testSendNowDuringALongStepAgainstRealDSH"
    exit 0 ;;
  "") ;;
  *) echo "unknown part $PART" >&2; exit 2 ;;
esac

demo_prepare_bridge
step "bridge tests (node:test, FakeDSH, golden fixtures; FollowUpAgainstFakeDSH, FollowUpQueueAgainstFakeDSH)"
demo_bridge_tests "$LOGS/bridge-test.log"
step "DSHKit tests (swift test, FakeBridge, golden fixtures; FollowUpTests, FollowUpQueueTests)"
demo_swift_tests "$LOGS/swift-test.log"

step "build the app and UI tests ($SIM)"
scripts/xc build-for-testing -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DSHM_DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  --log "$LOGS/build.log" || { grep -E "error:" "$LOGS/build.log"; exit 1; }

rm -f "$DSHM_FOLLOWUP_SHOTS"/*.png
if [ $STEER = 1 ]; then
  demo_part followup-ui-steer "$0" --part ui-steer
  EVIDENCE=${DSHM_EVIDENCE:-evidence/followup}
elif [ $RUNNING = 1 ]; then
  demo_part followup-ui-running "$0" --part ui-running
  EVIDENCE=${DSHM_EVIDENCE:-evidence/followup}
else
  demo_part followup-ui-real "$0" --part ui-real
  EVIDENCE=${DSHM_EVIDENCE:-evidence/followup}
fi

if [ $SHOTS = 1 ]; then
  step "screenshots → $EVIDENCE (1/3 size)"
  mkdir -p "$EVIDENCE"
  for f in "$DSHM_FOLLOWUP_SHOTS"/followup-*.png "$DSHM_FOLLOWUP_SHOTS"/steer-*.png; do
    [ -e "$f" ] || continue
    out="$EVIDENCE/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
step "follow-up demo passed"
