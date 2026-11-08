#!/bin/bash
# Model failures (ARCHITECTURE D104, D110, screens X1 and X4): demo and checks.
#
#   scripts/demo/model-failures.sh          bridge tests (the recorded DSH failures through FakeDSH),
#                                           swift test, and the real-DSH UI demo: a task on a provider
#                                           with no balance fails in red with the reason; after the
#                                           fake top-up, a new message in the same session continues it
#   scripts/demo/model-failures.sh --shots  also refresh the screenshots in evidence/S3/ (1/3 size)
#   DSHM_RESUME=1                           skip the parts that passed for the same code (lib.sh demo_part)
#
# Resources (WORKFLOW.md §6), from the environment (`eval "$(scripts/slice-env <ID>)"`):
#   DSHM_BRIDGE_PORT, DSHM_WEB_PORT, DSHM_HOME, DSHM_SIM, DSHM_DD (DerivedData).
# The real part runs scripts/demo/model-failures-host.mjs: DSH Web with the bridge plugin, and a
# fake DeepSeek provider (scripts/demo/fake-deepseek.mjs) in front of DSH's mock LLM, in a fresh
# DSH home under DSHM_HOME. Fails on any failed or skipped test.
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
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home-model-failures}" DSHM_SIM="${DSHM_SIM:-dshm-T0}"
export DSHM_DD="${DSHM_DD:-/tmp/dshm-model-failures-dd}"
export PATH="$HOME/.dshm/bin:$HOME/.nvm/versions/node/v24.14.0/bin:$PATH"
step() { printf '\n== %s\n' "$*"; }
SIM="$DSHM_SIM"
source scripts/demo/lib.sh
LOGS="/tmp/dshm-model-failures-${DSHM_SIM}"; mkdir -p "$LOGS" "$DSHM_HOME"
export DSHM_FAILURE_SHOTS="${DSHM_FAILURE_SHOTS:-$LOGS/shots}"; mkdir -p "$DSHM_FAILURE_SHOTS"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
export TEST_RUNNER_DSHM_SHOT_DIR="$DSHM_FAILURE_SHOTS"
REAL=dsh-mobileUITests/ModelFailuresUITests/testNoBalanceFailsInRedThenANewMessageContinuesAgainstRealDSH

case "$PART" in
  ui-real)
    step "UI: no balance fails in red, a new message continues (real DSH Web + bridge, fake DeepSeek)"
    for port in "$DSHM_BRIDGE_PORT" "$DSHM_WEB_PORT"; do
      ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null || { echo "model-failures: port $port is busy" >&2; exit 1; }
    done
    (cd bridge && corepack pnpm build >/dev/null)
    export DSHM_HOME="$(mktemp -d "$DSHM_HOME/run.XXXXXX")"
    export DSHM_FAILURE_SIGNALS="$(mktemp -d)"
    export TEST_RUNNER_DSHM_FAILURE_SIGNALS="$DSHM_FAILURE_SIGNALS"
    node scripts/demo/model-failures-host.mjs > "$LOGS/host.log" 2>&1 &
    host_pid=$!
    cleanup() { kill "$host_pid" 2>/dev/null || true; wait "$host_pid" 2>/dev/null || true; rm -rf "$DSHM_HOME" "$DSHM_FAILURE_SIGNALS"; }
    trap cleanup EXIT
    for _ in $(seq 1 360); do
      [ -e "$DSHM_FAILURE_SIGNALS/bridge-port" ] && break
      kill -0 "$host_pid" 2>/dev/null || { cat "$LOGS/host.log"; exit 1; }
      sleep 0.5
    done
    [ -e "$DSHM_FAILURE_SIGNALS/bridge-port" ] || { cat "$LOGS/host.log"; exit 1; }
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
step "bridge tests (node:test, FakeDSH, golden fixtures; ModelFailuresAgainstFakeDSH)"
demo_bridge_tests "$LOGS/bridge-test.log"
grep -E "ModelFailuresAgainstFakeDSH" "$LOGS/bridge-test.log" >/dev/null || { echo "ModelFailuresAgainstFakeDSH did not run" >&2; exit 1; }
step "DSHKit tests (swift test, FakeBridge, golden fixtures; ModelFailureTests)"
demo_swift_tests "$LOGS/swift-test.log"

step "build the app and UI tests ($SIM)"
xcodebuild build-for-testing -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DSHM_DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  > "$LOGS/build.log" 2>&1 || { grep -E "error:" "$LOGS/build.log"; exit 1; }

rm -f "$DSHM_FAILURE_SHOTS"/*.png
demo_part model-failures-ui-real "$0" --part ui-real

if [ $SHOTS = 1 ]; then
  step "screenshots → evidence/S3 (1/3 size)"
  mkdir -p evidence/S3
  for f in "$DSHM_FAILURE_SHOTS"/model-failure-*.png; do
    out="evidence/S3/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
step "model failures demo passed"
