#!/bin/bash
# Two TLS-authenticated clients on a disposable DSH profile. The CLI device dispatches
# the approvals demo's held fixture command; the simulated phone denies it, audits it, and revokes that CLI.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47816}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3289}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home-devices}"
export PATH="$HOME/.dshm/bin:$HOME/.nvm/versions/node/v24.14.0/bin:$PATH"
SIM="${DSHM_SIM:-dshm-devices}"
source scripts/demo/lib.sh
demo_tls_home
LOGS="/tmp/dshm-s10-${DSHM_BRIDGE_PORT:-47801}"; mkdir -p "$LOGS" "$DSHM_HOME"
FIXTURE=$(mktemp -d); PROFILE=$(mktemp -d "$DSHM_HOME/device-demo.XXXXXX")
host_pid=""; peer_pid=""
cleanup() {
  if [ -n "$peer_pid" ]; then kill "$peer_pid" 2>/dev/null || true; wait "$peer_pid" || true; fi
  if [ -n "$host_pid" ]; then kill "$host_pid" 2>/dev/null || true; wait "$host_pid" || true; fi
  rm -rf "$FIXTURE" "$PROFILE"
}
demo_tls_on_exit cleanup
mkdir "$FIXTURE/tmp"; echo 'keep' > "$FIXTURE/tmp/x"
export DSHM_APPROVALS_COMMAND="rm '$FIXTURE/tmp/x'"
demo_prepare_bridge
demo_bridge_tests "$LOGS/bridge-test.log"
demo_swift_tests "$LOGS/swift-test.log"

if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
args=(-project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST"
      -derivedDataPath "${DSHM_DD:-/tmp/dshm-devices-dd}" -parallel-testing-enabled NO -jobs 4
      -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates)
scripts/xc build-for-testing "${args[@]}" --log "$LOGS/build.log" || { grep -E 'error:|failed' "$LOGS/build.log" | tail -20; exit 1; }
: > "$LOGS/host.log"
DSHM_HOME="$PROFILE" node scripts/demo/approvals-host.mjs > "$LOGS/host.log" 2>&1 &
host_pid=$!
for _ in $(seq 1 180); do
  grep -q 'approvals-host: ready' "$LOGS/host.log" && break
  kill -0 "$host_pid" 2>/dev/null || { tail -20 "$LOGS/host.log"; exit 1; }
  sleep 0.5
done
grep -q 'approvals-host: ready' "$LOGS/host.log" || { echo "approval host did not start"; exit 1; }
pair_url() { DSH_HOME="$PROFILE" node bridge/lib/scripts/pair.js --url-only; }
identity="$FIXTURE/cli.json"
: > "$LOGS/peer.log"
demo_tls_client "$PROFILE" "$identity" 'Delete the demo fixture' > "$LOGS/peer.log" 2>&1 &
peer_pid=$!
for _ in $(seq 1 40); do [ -s "$LOGS/peer.log" ] && grep -q 'client: task session-' "$LOGS/peer.log" && break; sleep 0.5; done
grep -q 'client: task session-' "$LOGS/peer.log" || { tail -5 "$LOGS/peer.log"; exit 1; }
peer=$(node -e 'process.stdout.write(require(process.argv[1]).id)' "$identity")
export TEST_RUNNER_DSHM_DEVICES_PEER="$peer" TEST_RUNNER_DSHM_BRIDGE_PORT="$DSHM_BRIDGE_PORT"
export TEST_RUNNER_DSHM_PAIR_URL="$(pair_url)" TEST_RUNNER_DSHM_SHOT_DIR="$FIXTURE"
export TEST_RUNNER_DSHM_APPROVALS_COMMAND="$DSHM_APPROVALS_COMMAND"
demo_tls_ui test-without-building "${args[@]}" -only-testing:dsh-mobileUITests/DevicesUITests --log "$LOGS/ui.log" || {
  grep -E 'error:|Test Case' "$LOGS/ui.log" | tail -20; exit 1
}
grep -E 'Test Case.*testAuditAndRevokeAnotherPairedDevice.* passed' "$LOGS/ui.log"
demo_no_skipped_ui "$LOGS/ui.log"
wait "$peer_pid"; peer_pid=""
test "$(cat "$FIXTURE/tmp/x")" = 'keep'
if demo_tls_client "$PROFILE" "$identity" 'Must not run' > "$LOGS/reconnect.log" 2>&1; then
  echo "Revoked peer reconnected"; exit 1
fi
grep -F 'Unexpected server response: 403' "$LOGS/reconnect.log"
if [ "${1:-}" = --shots ]; then
  mkdir -p ${DSHM_EVIDENCE:-evidence/devices}
  for f in "$FIXTURE"/devices-*.png; do sips --resampleWidth 402 "$f" --out "${DSHM_EVIDENCE:-evidence/devices}/$(basename "$f")" >/dev/null; done
fi
echo 'devices demo passed'
