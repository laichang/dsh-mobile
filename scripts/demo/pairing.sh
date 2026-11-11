#!/bin/bash
#   scripts/demo/pairing.sh                  all checks, CLI pairing, UI tests in the Simulator
#   scripts/demo/pairing.sh --shots          also refresh the screenshots in evidence/pairing/
#   scripts/demo/pairing.sh --no-release     skip scripts/check-release-clean (two extra builds)
#
# Starts `node scripts/dsh-up.mjs` on the assigned port
# (DSH 0.2.2-rc.1 + DSH's mock LLM, no API key) with this slice's DSH home and ports, and stops
# it afterwards. The bridge listens on loopback with pinned TLS.
#
# Env (with defaults):
#   DSHM_BRIDGE_PORT  47810              DSHM_WEB_PORT  3283
#   DSHM_HOME         ~/.dshm/home-pairing    DSHM_SIM       dshm-pairing (name or UDID)
#   DSHM_DD           /tmp/dshm-pairing-dd (DerivedData; check-release-clean uses DSHM_RELEASE_DD)
# Fails on any failed or skipped test.
# Node 24 from ~/.nvm and the pnpm shim from ~/.dshm/bin are used if present.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0; RELEASE=1
for a in "$@"; do case "$a" in --shots) SHOTS=1 ;; --no-release) RELEASE=0 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47810}"
export DSHM_WEB_PORT="${DSHM_WEB_PORT:-3283}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home-pairing}"
SIM="${DSHM_SIM:-dshm-pairing}"
PORT="$DSHM_BRIDGE_PORT"
NODE24="$HOME/.nvm/versions/node/v24.14.0/bin"
[ -d "$NODE24" ] && export PATH="$NODE24:$PATH"
[ -d "$HOME/.dshm/bin" ] && export PATH="$HOME/.dshm/bin:$PATH"
LOGS="/tmp/dshm-s1-${DSHM_BRIDGE_PORT:-47801}"
mkdir -p "$LOGS"
step() { printf '\n== %s\n' "$*"; }
# pair.js finds the bridge's pairing state through DSH_HOME, like the bridge itself.
pair_url() { DSH_HOME="$DSHM_HOME" node bridge/lib/scripts/pair.js --url-only "$@"; }

source scripts/demo/lib.sh
demo_tls_home
demo_prepare_bridge

step "bridge tests (node:test: Noise vectors, golden transcripts, pairing against FakeDSH)"
demo_bridge_tests "$LOGS/bridge-test.log"

step "DSHKit tests (swift test: NoiseChannel, pairing against FakeNoiseHost, PlaintextChannel)"
demo_swift_tests "$LOGS/swift-test.log"

if [ $RELEASE = 1 ]; then
  step "Release carries no PlaintextChannel or other debug entry points"
  scripts/check-release-clean
fi

DSH_PID=""
cleanup() { [ -n "$DSH_PID" ] && kill "$DSH_PID" 2>/dev/null || true; }
demo_tls_on_exit cleanup
(cd bridge && corepack pnpm build >/dev/null)
if ! lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  step "starting real DSH + bridge (scripts/dsh-up.mjs: web $DSHM_WEB_PORT, bridge $PORT, $DSHM_HOME)"
  node scripts/dsh-up.mjs > "$LOGS/dsh-up.log" 2>&1 &
  DSH_PID=$!
  for _ in $(seq 1 240); do lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.5; done
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null || { cat "$LOGS/dsh-up.log"; echo "bridge did not come up" >&2; exit 1; }
fi
for _ in $(seq 1 40); do [ -f "$DSHM_HOME/dsh-mobile-bridge/listener.json" ] && break; sleep 0.25; done

step "CLI: enroll over TLS, run a task, reconnect with the device credential, run another"
ID="$DSHM_HOME/cli.json"; rm -f "$ID"
URL="$(pair_url)"
DSHM_DEMO_OFFER="$URL" demo_tls_client "$DSHM_HOME" "$ID" "用一句话介绍你自己。"
echo
demo_tls_client "$DSHM_HOME" "$ID" "Again, over TLS."
echo

step "CLI: the same pairing code again is refused (single use)"
if DSHM_DEMO_OFFER="$URL" demo_tls_client "$DSHM_HOME" "$DSHM_HOME/other.json" "should not run" 2> "$LOGS/reuse.err"; then
  echo "a reused pairing secret was accepted" >&2; exit 1
fi
rm -f "$LOGS/cli-other.json"
grep -Fq "client: enrollment refused" "$LOGS/reuse.err" || { echo "Expected an enrollment refusal from the host" >&2; exit 1; }

step "UI tests in the Simulator ($SIM): pairing, resume over TLS (durable list seam), round trip"
SHOT_DIR="$(mktemp -d)"
DD="${DSHM_DD:-/tmp/dshm-pairing-dd}"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR" TEST_RUNNER_DSHM_BRIDGE_PORT="$PORT" TEST_RUNNER_DSHM_REAL_DSH=1
scripts/xc build-for-testing -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  --log "$LOGS/build.log" || { grep -E "error:" "$LOGS/build.log"; exit 1; }
export TEST_RUNNER_DSHM_PAIR_URL="$(pair_url)"
export TEST_RUNNER_DSHM_EXPIRED_PAIR_URL="$(pair_url --ttl-minutes 0.001)"
uitest() { # name, then -only-testing targets; fails on any failed or skipped test
  local name=$1; shift
  demo_tls_ui test-without-building -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
    -derivedDataPath "$DD" "$@" --log "$LOGS/uitest-$name.log" \
    || { grep -E "error:|Test Case|XCTAssert" "$LOGS/uitest-$name.log"; exit 1; }
  grep -E "Test Case.*(passed|failed|skipped)" "$LOGS/uitest-$name.log"
  demo_no_skipped_ui "$LOGS/uitest-$name.log"
}
uitest pairing \
  -only-testing:dsh-mobileUITests/PairingUITests/testExpiredPairingLinkIsRefused \
  -only-testing:dsh-mobileUITests/PairingUITests/testPairViaDeepLinkThenDemoOverTLS \
  -only-testing:dsh-mobileUITests/PairingUITests/testRelaunchReconnectsOverTLS

step "UI: kill the paired app; a task runs on the bridge meanwhile; reopen: TLS reconnect + resume fills the gap"
TEST_RUNNER_DSHM_RESUME_PHASE=1 uitest resume1 \
  -only-testing:dsh-mobileUITests/PairingUITests/testResumeOverTLSPhase1KillWhileConnected
GAP_PROMPT="While the app was closed $(date +%s)"
demo_tls_client "$DSHM_HOME" "$ID" "$GAP_PROMPT" >/dev/null && echo "client: ran \"$GAP_PROMPT\" while the app was closed"
TEST_RUNNER_DSHM_RESUME_PHASE=2 TEST_RUNNER_DSHM_GAP_PROMPT="$GAP_PROMPT" uitest resume2 \
  -only-testing:dsh-mobileUITests/PairingUITests/testResumeOverTLSPhase2GapFilled

step "UI: round trip demo (resets pairing, so it runs last)"
uitest t0 -only-testing:dsh-mobileUITests/RoundTripUITests

step "bridge device registry"
node --input-type=module - "$DSHM_HOME/dsh-mobile-bridge" <<'JS'
import { readFileSync } from 'node:fs'
const { devices } = JSON.parse(readFileSync(process.argv[2] + '/tls/devices.json', 'utf8'))
console.log(devices.length + ' device(s): ' + devices.map(device => device.id).join(', '))
JS

if [ $SHOTS = 1 ]; then
  step "screenshots → ${DSHM_EVIDENCE:-evidence/pairing} (1/3 size)"
  mkdir -p ${DSHM_EVIDENCE:-evidence/pairing}
  for f in "$SHOT_DIR"/pairing-*.png; do
    out="${DSHM_EVIDENCE:-evidence/pairing}/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
step "pairing demo passed"
