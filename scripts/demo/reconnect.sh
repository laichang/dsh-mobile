#!/bin/bash
# Reconnect to every saved address of a host, on real DSH and an iOS Simulator (screen H,
# ARCHITECTURE D21 e, D98).
#
# The host has two addresses. The first (DSHM_SECOND_BRIDGE_PORT) is a proxy that forwards one
# connection and then dies (scripts/demo/reconnect-proxy.mjs); the second (DSHM_BRIDGE_PORT) is
# the bridge. The app pairs through the first, so it saves [first, second]. Its reconnect then
# finds the first dead, connects through the second, shows the host online and runs a task. The
# hosts sheet names the address in use. Then the script stops DSH, and the app shows the host
# offline with the error of each address.
#
#   scripts/demo/reconnect.sh           DSHKit tests, then the UI tests on real DSH (Noise)
#   scripts/demo/reconnect.sh --shots   also refresh the screenshots in evidence/S7/ (1/3 size)
#   DSHM_RESUME=1                      skip the parts that passed for the same code (lib.sh demo_part)
#
# Resources (scripts/slice-env): DSHM_BRIDGE_PORT, DSHM_SECOND_BRIDGE_PORT, DSHM_WEB_PORT,
# DSHM_HOME, DSHM_SIM, DSHM_DD. Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0
for a in "$@"; do case "$a" in --shots) SHOTS=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47800}" DSHM_SECOND_BRIDGE_PORT="${DSHM_SECOND_BRIDGE_PORT:-47830}"
export DSHM_WEB_PORT="${DSHM_WEB_PORT:-3283}" DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home}"
export DSHM_SIM="${DSHM_SIM:-iPhone 17 Pro}" DSHM_DD="${DSHM_DD:-/tmp/dshm-reconnect-dd}"
export PATH="$HOME/.dshm/bin:$HOME/.nvm/versions/node/v24.14.0/bin:$PATH"
step() { printf '\n== %s\n' "$*"; }
source scripts/demo/lib.sh
LOGS=/tmp/dshm-reconnect-$DSHM_BRIDGE_PORT; mkdir -p "$LOGS"
SIM="$DSHM_SIM"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
SHOT_DIR="$(mktemp -d)"
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR" TEST_RUNNER_DSHM_BRIDGE_PORT="$DSHM_BRIDGE_PORT"
export TEST_RUNNER_DSHM_DEAD_PORT="$DSHM_SECOND_BRIDGE_PORT"

DSH_PID=""; PROXY_PID=""
stop() { if [ -n "$1" ]; then kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; fi; }
cleanup() { stop "$DSH_PID"; stop "$PROXY_PID"; rm -rf "$SHOT_DIR"; }
trap cleanup EXIT

step "DSHKit tests (swift test, fake hosts)"
demo_part reconnect-swift-test bash -c 'source scripts/demo/lib.sh; demo_swift_tests "$1"' _ "$LOGS/swift-test.log"

demo_prepare_bridge
(cd bridge && corepack pnpm build >/dev/null)

step "build the app and UI tests ($SIM)"
xcodebuild build-for-testing -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DSHM_DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  > "$LOGS/build.log" 2>&1 || { grep -E "error:" "$LOGS/build.log"; exit 1; }

ui_part() { # name, then -only-testing selectors
  local name=$1; shift
  local args=() t
  for t in "$@"; do args+=("-only-testing:dsh-mobileUITests/$t"); done
  step "UI: $name (log: $LOGS/ui-$name.log)"
  if demo_part "ui-$name" xcodebuild test-without-building -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile \
      -destination "$DEST" -derivedDataPath "$DSHM_DD" -parallel-testing-enabled NO "${args[@]}" \
      > "$LOGS/ui-$name.log" 2>&1; then
    grep -E "Test Case.*(passed|failed|skipped)" "$LOGS/ui-$name.log" || true
  else
    grep -E "error:|Test Case.*(passed|failed)" "$LOGS/ui-$name.log" || tail -30 "$LOGS/ui-$name.log"
    echo "UI tests failed: $name" >&2
    exit 1
  fi
  demo_no_skipped_ui "$LOGS/ui-$name.log"
}

for p in "$DSHM_BRIDGE_PORT" "$DSHM_SECOND_BRIDGE_PORT"; do
  if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then echo "port $p is in use" >&2; exit 1; fi
done

step "real DSH + bridge with Noise only (web $DSHM_WEB_PORT, bridge $DSHM_BRIDGE_PORT, $DSHM_HOME)"
mkdir -p "$DSHM_HOME"
DSHM_BRIDGE_DEV_PLAINTEXT=0 node scripts/dsh-up.mjs > "$LOGS/dsh-up.log" 2>&1 &
DSH_PID=$!
for _ in $(seq 1 240); do lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.5; done
lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null || { tail -20 "$LOGS/dsh-up.log"; echo "bridge did not come up" >&2; exit 1; }
for _ in $(seq 1 40); do [ -f "$DSHM_HOME/dsh-mobile-bridge/listener.json" ] && break; sleep 0.25; done

step "first address: a proxy on $DSHM_SECOND_BRIDGE_PORT that dies after one connection"
node scripts/demo/reconnect-proxy.mjs "$DSHM_SECOND_BRIDGE_PORT" "$DSHM_BRIDGE_PORT" > "$LOGS/proxy.log" 2>&1 &
PROXY_PID=$!
for _ in $(seq 1 40); do grep -q 'reconnect-proxy: ready' "$LOGS/proxy.log" && break; sleep 0.25; done
grep -q 'reconnect-proxy: ready' "$LOGS/proxy.log" || { cat "$LOGS/proxy.log"; echo "proxy did not come up" >&2; exit 1; }

# The pairing link with the two addresses, the proxy first (the `a` field, bridge/src/pairing/offer.ts).
ADDRS="127.0.0.1:$DSHM_SECOND_BRIDGE_PORT,127.0.0.1:$DSHM_BRIDGE_PORT"
URL="$(DSH_HOME="$DSHM_HOME" node bridge/lib/scripts/pair.js --url-only)"
URL="$(node -e 'const u=new URL(process.argv[1]); u.searchParams.set("a", process.argv[2]); console.log(u.toString())' "$URL" "$ADDRS")"
echo "pairing addresses: $ADDRS"
TEST_RUNNER_DSHM_RECONNECT_PAIR_URL="$URL" ui_part reconnect-dead-first \
  ReconnectUITests/testDeadFirstAddressFallsThroughToTheSecond
cat "$LOGS/proxy.log"

step "stop DSH: every address of the host is dead"
stop "$DSH_PID"; DSH_PID=""
stop "$PROXY_PID"; PROXY_PID=""
TEST_RUNNER_DSHM_RECONNECT_ALL_DEAD=1 ui_part reconnect-all-dead ReconnectUITests/testAllAddressesDeadShowEachError

if [ $SHOTS = 1 ]; then
  step "screenshots → evidence/S7 (1/3 size)"
  mkdir -p evidence/S7
  for f in "$SHOT_DIR"/reconnect-*.png; do
    [ -e "$f" ] || { echo "no new shots (the UI parts were skipped)"; break; }
    out="evidence/S7/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
step "reconnect demo passed"
