#!/bin/bash
# Two FakeBridge hosts for offline behavior, two real Noise hosts for rich detail/devices integration.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0
for arg in "$@"; do case "$arg" in --shots) SHOTS=1 ;; *) echo "unknown arg $arg" >&2; exit 2 ;; esac; done
export PATH="$HOME/.dshm/bin:$HOME/.nvm/versions/node/v24.14.0/bin:$PATH"
SIM="${DSHM_SIM:-dshm-multi-host}"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
LOGS=/tmp/dshm-s9; mkdir -p "$LOGS"
source scripts/demo/lib.sh
demo_prepare_bridge
demo_bridge_tests "$LOGS/bridge.log"
demo_swift_tests "$LOGS/swift.log"
# Both real hosts run in fresh profiles, so the simulator can distinguish their paired devices.
home="${DSHM_HOME:-$HOME/.dshm/home-multi-host}"
mkdir -p "$home"
profiles=$(mktemp -d "$home/paired.XXXXXX")
ports=("${DSHM_BRIDGE_PORT:-47817}" "${DSHM_SECOND_BRIDGE_PORT:-47820}")
web=("${DSHM_WEB_PORT:-3290}" "${DSHM_SECOND_WEB_PORT:-3293}")
pids=()
cleanup() {
  if (( ${#pids[@]} )); then
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
  fi
  rm -rf "$profiles"
}
trap cleanup EXIT
for port in "${ports[@]}" "${web[@]}"; do
  ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null || { echo "multi-host port $port is busy" >&2; exit 1; }
done
for i in 0 1; do
  DSHM_HOME="$profiles/host-$i" DSHM_BRIDGE_PORT="${ports[i]}" DSHM_WEB_PORT="${web[i]}" \
    DSHM_MOCK_TEXT="Hello from host $i." DSHM_MOCK_CHUNK_DELAY_MS=5 \
    node scripts/demo/durable-list-host.mjs >"$LOGS/host-$i.log" 2>&1 &
  pids+=("$!")
  for _ in $(seq 1 180); do
    lsof -nP -iTCP:"${ports[i]}" -sTCP:LISTEN >/dev/null && break
    kill -0 "${pids[i]}" 2>/dev/null || { tail "$LOGS/host-$i.log"; exit 1; }
    sleep 0.5
  done
  lsof -nP -iTCP:"${ports[i]}" -sTCP:LISTEN >/dev/null || { echo "multi-host host $i did not start"; exit 1; }
done
offer() { DSH_HOME="$profiles/host-$1" node bridge/lib/scripts/pair.js --url-only; }
# This CLI's key is registered only with host 0. The iPhone's own key pairs with both.
node bridge/lib/scripts/client.js --identity "$profiles/peer.json" --pair "$(offer 0)" "Warm host zero" >"$LOGS/peer.log" 2>&1
node bridge/lib/scripts/client.js --port "${ports[1]}" "Warm host one" >"$LOGS/warm.log" 2>&1
export TEST_RUNNER_DSHM_MULTIHOST_PEER="$(node --input-type=module - "$profiles/peer.json" <<'JS'
import { readFileSync } from 'node:fs'
import { keyPairFromSecret } from './bridge/lib/src/pairing/noise.js'
import { deviceId } from './bridge/lib/src/pairing/store.js'
const key = JSON.parse(readFileSync(process.argv[2])).secretKey
console.log(deviceId(keyPairFromSecret(Buffer.from(key, 'base64url')).publicKey))
JS
)"
export TEST_RUNNER_DSHM_MULTIHOST_OFFER_0="$(offer 0)" TEST_RUNNER_DSHM_MULTIHOST_OFFER_1="$(offer 1)"
export TEST_RUNNER_DSHM_MULTIHOST_PORT_0="${ports[0]}" TEST_RUNNER_DSHM_MULTIHOST_PORT_1="${ports[1]}"
export TEST_RUNNER_DSHM_SHOT_DIR="$(mktemp -d)"
scripts/xc test -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "${DSHM_DD:-/tmp/dshm-multi-host-dd}" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  -parallel-testing-enabled NO -jobs 4 -only-testing:dsh-mobileUITests/MultiHostUITests \
  -only-testing:dsh-mobileUITests/PairedHostsUITests --log "$LOGS/ui.log" || {
    grep -E 'error:|Test Case|XCTAssert' "$LOGS/ui.log"; exit 1;
  }
grep -E 'Test Case.*testTwoHostsShareTheListAndTheOfflineHostIsNamed.*passed' "$LOGS/ui.log"
grep -E 'Test Case.*testPairedDevicesAndInlineAnswersStayWithTheirHost.*passed' "$LOGS/ui.log"
demo_no_skipped_ui "$LOGS/ui.log"
if [[ "$SHOTS" == 1 ]]; then
  mkdir -p ${DSHM_EVIDENCE:-evidence/multi-host}
  for name in multi-host-two-hosts multi-host-office-offline; do
    sips --resampleWidth 402 "$TEST_RUNNER_DSHM_SHOT_DIR/$name.png" --out "${DSHM_EVIDENCE:-evidence/multi-host}/$name.png" >/dev/null
  done
fi
echo 'multi-host demo passed'
