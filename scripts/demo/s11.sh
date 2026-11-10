#!/bin/bash
# Real first run: remove the app on the designated simulator, then pair a Release build with DSH.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47819}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3292}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home-s11}"
export PATH="$HOME/.dshm/bin:$HOME/.nvm/versions/node/v24.14.0/bin:$PATH"
SIM="${DSHM_SIM:-dshm-S11}"
LOGS=/tmp/dshm-s11
mkdir -p "$LOGS" "$DSHM_HOME"
PROFILE=$(mktemp -d "$DSHM_HOME/first-run.XXXXXX")
SHOTS=$(mktemp -d)
host_pid=""
registry_path() {
  local data
  data=$(xcrun simctl get_app_container "$SIM" chang.dsh-mobile data) || return 1
  printf '%s/Library/Application Support/paired-hosts.json\n' "$data"
}
cleanup() {
  if [ -n "$host_pid" ]; then kill "$host_pid" 2>/dev/null || true; wait "$host_pid" || true; fi
  if [ -f "$SHOTS/paired-hosts.json" ]; then cp "$SHOTS/paired-hosts.json" "$(registry_path)"; fi
  rm -rf "$PROFILE" "$SHOTS"
}
trap cleanup EXIT

source scripts/demo/lib.sh
demo_prepare_bridge
demo_bridge_tests "$LOGS/bridge.log"
demo_swift_tests "$LOGS/swift.log"

if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
args=(-project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -configuration Release -destination "$DEST"
      -derivedDataPath "${DSHM_DD:-/tmp/dshm-s11-dd}" -parallel-testing-enabled NO -jobs 4 ONLY_ACTIVE_ARCH=YES
      -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates)
scripts/xc build-for-testing "${args[@]}" --log "$LOGS/build.log" || { grep -E 'error:|failed' "$LOGS/build.log" | tail -20; exit 1; }
xcrun simctl bootstatus "$SIM" -b >/dev/null
if xcrun simctl get_app_container "$SIM" chang.dsh-mobile app >/dev/null 2>&1; then
  xcrun simctl uninstall "$SIM" chang.dsh-mobile
fi
if lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null; then echo "S11 bridge port is busy" >&2; exit 1; fi
DSHM_HOME="$PROFILE" DSHM_BRIDGE_DEV_PLAINTEXT=0 node scripts/dsh-up.mjs > "$LOGS/host.log" 2>&1 &
host_pid=$!
for _ in $(seq 1 180); do
  lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null && break
  kill -0 "$host_pid" 2>/dev/null || { tail -10 "$LOGS/host.log"; exit 1; }
  sleep 0.5
done
lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null || { echo "S11 host did not start"; exit 1; }
pair_url() { DSH_HOME="$PROFILE" node bridge/lib/scripts/pair.js --url-only; }
# An existing DSH account may already have tasks when this phone pairs for the first time.
node bridge/lib/scripts/client.js --identity "$SHOTS/peer.json" --pair "$(pair_url)" 'Earlier task from another device' > "$LOGS/peer.log"

export TEST_RUNNER_DSHM_PAIR_URL="$(pair_url)" TEST_RUNNER_DSHM_SHOT_DIR="$SHOTS"
# Run the unpaired language check first, before the end-to-end case pairs the simulator.
run_ui() {
  local test=$1
  local log="$LOGS/$test.log"
  scripts/xc test-without-building "${args[@]}" -only-testing:"dsh-mobileUITests/S11FirstRunUITests/$test" \
    --log "$log" || { grep -E 'error:|Test Case' "$log" | tail -20; exit 1; }
  grep -E "Test Case.*$test.*passed" "$log"
  demo_no_skipped_ui "$log"
}
run_ui testChineseWelcomeAndGuide
run_ui testFirstRunFromWelcomeToReply

# This simulator was freshly installed and paired by the test above. Keep the registered host
# but remove its address to exercise the Release recovery path; cleanup restores the original.
registry=$(registry_path)
cp "$registry" "$SHOTS/paired-hosts.json"
node --input-type=module - "$registry" <<'JS'
import { readFileSync, writeFileSync } from 'node:fs'
const path = process.argv[2]
const hosts = JSON.parse(readFileSync(path, 'utf8'))
if (hosts.length !== 1) throw Error('expected the paired S11 demo host')
hosts[0].addresses = []
writeFileSync(path, JSON.stringify(hosts))
JS
export TEST_RUNNER_DSHM_S11_RECOVERY=1
run_ui testSavedHostWithoutAnAddressOffersRecovery
if [ "${1:-}" = --shots ]; then
  mkdir -p evidence/S11
  for f in "$SHOTS"/s11-*.png; do sips --resampleWidth 402 "$f" --out "evidence/S11/$(basename "$f")" >/dev/null; done
fi
echo 'S11 demo passed'
