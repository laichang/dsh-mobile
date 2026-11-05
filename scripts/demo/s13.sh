#!/bin/bash
# A real DSH Web peer sends four turns. The Simulator keeps the same detail open across a connection loss.
set -euo pipefail
cd "$(dirname "$0")/../.."
case "${1:-}" in ""|--shots) ;; *) echo "usage: $0 [--shots]" >&2; exit 2 ;; esac
export PATH="$HOME/.dshm/bin:$HOME/.nvm/versions/node/v24.14.0/bin:$PATH"
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47810}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3283}"
export DSHM_BRIDGE_HOST=127.0.0.1 DSHM_BRIDGE_DEV_PLAINTEXT=1
SIM="${DSHM_SIM:-dshm-S13}"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then dest="platform=iOS Simulator,id=$SIM"; else dest="platform=iOS Simulator,name=$SIM"; fi
logs=/tmp/dshm-s13-demo
mkdir -p "$logs"
source scripts/demo/lib.sh
demo_prepare_bridge
demo_bridge_tests "$logs/bridge.log"
demo_swift_tests "$logs/swift.log"
for port in "$DSHM_BRIDGE_PORT" "$DSHM_WEB_PORT"; do
  ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null || { echo "S13 port $port is busy" >&2; exit 1; }
done
# initializeDefault is only eligible on first use. Give each run a fresh host profile.
base="${DSHM_HOME:-$HOME/.dshm/home-s13}"
mkdir -p "$base"
export DSHM_HOME="$(mktemp -d "$base/run.XXXXXX")"
export DSHM_S13_SIGNALS="$(mktemp -d)"
export TEST_RUNNER_DSHM_S13_SIGNALS="$DSHM_S13_SIGNALS" TEST_RUNNER_DSHM_SHOT_DIR="$DSHM_S13_SIGNALS"
node scripts/demo/s13-web.mjs > "$logs/web.log" 2>&1 &
web_pid=$!
cleanup() {
  kill "$web_pid" 2>/dev/null || true
  wait "$web_pid" 2>/dev/null || true
  rm -rf "$DSHM_HOME" "$DSHM_S13_SIGNALS"
}
trap cleanup EXIT
for _ in $(seq 1 240); do
  [ -e "$DSHM_S13_SIGNALS/first-ready" ] && break
  kill -0 "$web_pid" 2>/dev/null || { cat "$logs/web.log"; exit 1; }
  sleep 0.5
done
[ -e "$DSHM_S13_SIGNALS/first-ready" ] || { cat "$logs/web.log"; exit 1; }
xcodebuild test -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$dest" \
  -derivedDataPath "${DSHM_DD:-/tmp/dshm-s13-dd}" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  -jobs 4 -parallel-testing-enabled NO -only-testing:dsh-mobileUITests/S13SessionVisibilityUITests > "$logs/ui.log" 2>&1 || {
    grep -E 'error:|Test Case|failed' "$logs/ui.log"; cat "$logs/web.log"; exit 1;
  }
grep -E 'Test Case.*testWebTurnsUpdateOpenDetailAndResumeAfterDisconnect.*passed' "$logs/ui.log"
demo_no_skipped_ui "$logs/ui.log"
wait "$web_pid" || { cat "$logs/web.log"; exit 1; }
if [[ "${1:-}" == --shots ]]; then
  mkdir -p evidence/S13
  for name in s13-live-turn s13-reconnected; do
    sips --resampleWidth 402 "$DSHM_S13_SIGNALS/$name.png" --out "evidence/S13/$name.png" >/dev/null
  done
fi
echo "S13 demo passed"
