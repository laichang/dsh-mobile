#!/bin/bash
# Exercise enrollment and reconnection with the real plugin and iOS app.
set -euo pipefail
cd "$(dirname "$0")/../.."
export PATH="$HOME/.dshm/bin:$HOME/.nvm/versions/node/v24.14.0/bin:$PATH"
SIM="${DSHM_SIM:?set the slice simulator}"
source scripts/demo/lib.sh
run=$(mktemp -d)
chmod 700 "$run"
pid=""
watcher=""
cleanup() {
  if [[ -n "$watcher" ]]; then kill "$watcher" 2>/dev/null || true; wait "$watcher" 2>/dev/null || true; fi
  if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  rm -rf "$run"
}
trap cleanup EXIT
(cd bridge && corepack pnpm install --frozen-lockfile >/dev/null && corepack pnpm build)
scripts/pnpm-test --node-test lib/test/tls-enrollment.test.js
export DSHM_HOME="$run/home" DSHM_BRIDGE_TLS=1 DSHM_BRIDGE_DEV_PLAINTEXT=0
state="$DSHM_HOME/dsh-mobile-bridge"
start_host() {
  node scripts/dsh-up.mjs > "$run/host.log" 2>&1 &
  pid=$!
  for _ in {1..160}; do
    [[ -s "$state/listener.json" ]] && lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null 2>&1 && break
    kill -0 "$pid" 2>/dev/null || { tail -6 "$run/host.log"; exit 1; }
    sleep 0.5
  done
  node -e 'if (!require(process.argv[1]).tls) process.exit(1)' "$state/listener.json"
}
stop_host() {
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pid=""
  for _ in {1..50}; do lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null 2>&1 || return 0; sleep 0.2; done
  echo "enrollment test port still busy" >&2; return 1
}
start_host
for name in REVOKE_PAIR_URL REVOKE_PAIR_URL_2 TLS_PAIR_URL; do
  (umask 077; DSH_HOME="$DSHM_HOME" node bridge/lib/scripts/pair.js --url-only > "$run/$name")
  export "TEST_RUNNER_DSHM_${name}_FILE=$run/$name"
done
(
  while true; do
    for marker in "$run"/*.open; do
      [[ -f "$marker" ]] || continue
      rm -f "$marker"
      xcrun simctl openurl "$SIM" "$(cat "${marker%.open}")" >/dev/null 2>&1
    done
    sleep 0.2
  done
) &
watcher=$!
args=(-project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "platform=iOS Simulator,id=$SIM"
  -derivedDataPath "${DSHM_DD:-/tmp/dshm-tls-enroll-$SIM-dd}" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates
  -parallel-testing-enabled NO)
scripts/xc build-for-testing "${args[@]}"
ui() {
  local log="$run/$1.log"; shift
  scripts/xc test-without-building "${args[@]}" "$@" --log "$log" || { rg 'failed|error:' "$log" | tail -10; return 1; }
  demo_no_skipped_ui "$log"
}
ui management -only-testing:dsh-mobileUITests/RevokeUITests/testRevokeThisDeviceInHostsSheetOnTheRealBridgeOpens08AndStays \
  -only-testing:dsh-mobileUITests/RevokeUITests/testRevokeThisDeviceInDrawerDevicesOnTheRealBridgeOpens08AndStays
ui dispatch -only-testing:dsh-mobileUITests/RevokeUITests/testEnrolledPhoneDispatchesAfterRelaunch
stop_host
export TEST_RUNNER_DSHM_TLS_UNAVAILABLE=1
ui unreachable -only-testing:dsh-mobileUITests/RevokeUITests/testUnreachableTLSHostRetainsPairingAndCachedTask
for mode in wrong-key redirect unrelated; do
  rm -f "$run/counts.json"
  node bridge/lib/test/tls-unavailable-peer.js "$mode" "$state" "$run" "$DSHM_BRIDGE_PORT" &
  pid=$!
  for _ in {1..100}; do [[ -s "$run/counts.json" ]] && break; sleep 0.1; done
  ui "$mode" -only-testing:dsh-mobileUITests/RevokeUITests/testUnreachableTLSHostRetainsPairingAndCachedTask
  node - "$mode" "$run/counts.json" <<'JS'
const { received, authenticated, forwarded } = require(process.argv[3])
const { ok } = require('node:assert/strict')
ok(process.argv[2] === 'wrong-key' ? received === 0 : authenticated > 0)
ok(forwarded === 0)
JS
  stop_host
done
start_host
(cd bridge && node lib/test/tls-client.js "$state")
export TEST_RUNNER_DSHM_TLS_OFFLINE_REVOKE=1
ui offline -only-testing:dsh-mobileUITests/RevokeUITests/testOfflineRevokedPhoneForgetsHostOnLaunch
echo "TLS enrollment and revocation passed."
