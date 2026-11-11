#!/bin/bash
# Interrupt a streaming task on real DSH with the durable list's slow mock model.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0
for arg in "$@"; do case "$arg" in --shots) SHOTS=1 ;; *) echo "unknown arg $arg" >&2; exit 2 ;; esac; done
export PATH="$HOME/.dshm/bin:$HOME/.nvm/versions/node/v24.14.0/bin:$PATH"
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47811}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3284}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home-interrupt}" DSHM_MOCK_CHUNK_DELAY_MS=800
SIM="${DSHM_SIM:-dshm-interrupt}"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
LOGS="/tmp/dshm-s5-${DSHM_BRIDGE_PORT:-47801}"
mkdir -p "$LOGS"
source scripts/demo/lib.sh
demo_tls_home
demo_prepare_bridge
demo_bridge_tests "$LOGS/bridge.log"
demo_swift_tests "$LOGS/swift.log"
if lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null; then
  echo "interrupt needs its own slow host; bridge port $DSHM_BRIDGE_PORT is busy" >&2; exit 1
fi
node scripts/demo/durable-list-host.mjs > "$LOGS/host.log" 2>&1 &
host_pid=$!
demo_tls_on_exit 'kill "$host_pid" 2>/dev/null || true'
for _ in $(seq 1 240); do
  lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null && break
  kill -0 "$host_pid" 2>/dev/null || { tail -12 "$LOGS/host.log"; exit 1; }
  sleep 0.5
done
lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null || { echo "interrupt bridge did not start" >&2; exit 1; }
shot_dir="$(mktemp -d)"
export TEST_RUNNER_DSHM_REAL_DSH=1 TEST_RUNNER_DSHM_BRIDGE_PORT="$DSHM_BRIDGE_PORT" TEST_RUNNER_DSHM_SHOT_DIR="$shot_dir"
demo_tls_ui test -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "${DSHM_DD:-/tmp/dshm-interrupt-dd}" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  -parallel-testing-enabled NO -jobs 4 -only-testing:dsh-mobileUITests/InterruptUITests --log "$LOGS/ui.log" || {
    grep -E 'error:|Test Case' "$LOGS/ui.log"; exit 1;
  }
grep -E "Test Case.*testInterruptLongRunningTask.* passed" "$LOGS/ui.log"
demo_no_skipped_ui "$LOGS/ui.log"
if [ "$SHOTS" = 1 ]; then
  mkdir -p ${DSHM_EVIDENCE:-evidence/interrupt}
  sips --resampleWidth 402 "$shot_dir/interrupt-interrupted-detail.png" --out ${DSHM_EVIDENCE:-evidence/interrupt}/interrupt-interrupted-detail.png >/dev/null
fi
echo "interrupt demo passed"
