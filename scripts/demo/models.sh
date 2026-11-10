#!/bin/bash
# Real DSH + slow mock, so the Simulator can switch the effort during the turn.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47812}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3285}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home-models}" DSHM_MOCK_CHUNK_DELAY_MS=2400
SIM="${DSHM_SIM:-dshm-models}"
DD="${DSHM_DD:-/tmp/dshm-models-dd}"
export PATH="$HOME/.dshm/bin:$HOME/.nvm/versions/node/v24.14.0/bin:$PATH"
source scripts/demo/lib.sh
LOGS=/tmp/dshm-s6
mkdir -p "$LOGS"
demo_prepare_bridge
demo_bridge_tests "$LOGS/bridge.log"
demo_swift_tests "$LOGS/swift.log"
if ! lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  node scripts/demo/durable-list-host.mjs > "$LOGS/host.log" 2>&1 &
  host_pid=$!
  trap 'kill "$host_pid" 2>/dev/null || true' EXIT
  for _ in $(seq 1 240); do
    lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null 2>&1 && break
    kill -0 "$host_pid" 2>/dev/null || { tail -12 "$LOGS/host.log"; exit 1; }
    sleep 0.5
  done
  lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null
fi
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
export TEST_RUNNER_DSHM_BRIDGE_PORT="$DSHM_BRIDGE_PORT" TEST_RUNNER_DSHM_SHOT_DIR="$(mktemp -d)"
scripts/xc test -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  -parallel-testing-enabled NO -only-testing:dsh-mobileUITests/ModelsUITests --log "$LOGS/ui.log" || {
    grep -E 'error:|Test Case|failed' "$LOGS/ui.log"; exit 1;
  }
grep -E "Test Case.*passed" "$LOGS/ui.log"
demo_no_skipped_ui "$LOGS/ui.log"
if [[ "${1:-}" == --shots ]]; then
  mkdir -p ${DSHM_EVIDENCE:-evidence/models}
  sips --resampleWidth 402 "$TEST_RUNNER_DSHM_SHOT_DIR/models-effort-switch.png" --out ${DSHM_EVIDENCE:-evidence/models}/models-effort-switch.png >/dev/null
fi
