#!/bin/bash
# Runs the production bridge inside an actual out-of-range DSH, then opens the iOS app.
set -euo pipefail
cd "$(dirname "$0")/../.."
export PATH="$HOME/.dshm/bin:$HOME/.nvm/versions/node/v24.14.0/bin:$PATH"
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47818}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3291}"
SIM="${DSHM_SIM:-dshm-S12}"
export DSHM_BRIDGE_HOST=127.0.0.1 DSHM_BRIDGE_DEV_PLAINTEXT=1
profile_parent="${DSHM_HOME:-$HOME/.dshm/home-s12}"
mkdir -p "$profile_parent"
export DSH_HOME="$(mktemp -d "$profile_parent/demo.XXXXXX")"
runtime="$HOME/.dshm/runtime-s12-0.2.2-alpha.3"
dsh="$runtime/node_modules/.bin/dsh"
if [ ! -x "$dsh" ]; then
  mkdir -p "$runtime"
  npm install --prefix "$runtime" --save-exact --no-fund --no-audit @deepseek-ai/dsh@0.2.2-alpha.3
fi
logs=/tmp/dshm-s12-demo
mkdir -p "$logs"
pid=''
cleanup() { if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" || true; fi; rm -rf "$DSH_HOME"; }
trap cleanup EXIT
source scripts/demo/lib.sh
demo_prepare_bridge
demo_bridge_tests "$logs/bridge.log"
demo_swift_tests "$logs/swift.log"
"$dsh" plugin --profile web add "$PWD/bridge" > "$logs/add.log" 2>&1
"$dsh" web --no-open --port "$DSHM_WEB_PORT" > "$logs/host.log" 2>&1 &
pid=$!
for _ in $(seq 1 160); do
  lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null && break
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.5
done
lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null || { echo "Out-of-range DSH failed to start; see $logs/host.log"; exit 1; }
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
export TEST_RUNNER_DSHM_BRIDGE_PORT="$DSHM_BRIDGE_PORT" TEST_RUNNER_DSHM_SHOT_DIR="$DSH_HOME"
scripts/xc test -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "${DSHM_DD:-/tmp/dshm-s12-dd}" -parallel-testing-enabled NO -jobs 4 \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -only-testing:dsh-mobileUITests/S12UpstreamUITests \
  --log "$logs/ui.log" || { grep -E 'error:|Test Case' "$logs/ui.log" | tail -20; exit 1; }
grep -E 'Test Case.*testUnsupportedHostDisplaysBridgeUpdateAndKeepsPrompt.* passed' "$logs/ui.log"
demo_no_skipped_ui "$logs/ui.log"
if [ "${1:-}" = --shots ]; then
  mkdir -p evidence/S12
  sips --resampleWidth 402 "$DSH_HOME/s12-update-required.png" --out evidence/S12/s12-update-required.png >/dev/null
fi
echo 'S12 demo passed'
