#!/bin/bash
# The bridge cannot listen because another program holds its port: the bridge says why in DSH's
# log, and the phone says why on the host row (H) and the offline card (X3). Real DSH and an iOS
# Simulator (ARCHITECTURE D125).
#
# 1. DSH and its bridge run on DSHM_BRIDGE_PORT; the app pairs with them.
# 2. The script stops DSH, starts another program on that port (scripts/demo/port-holder.mjs, an
#    HTTP server) and starts DSH again. The bridge cannot listen: DSH's log has one line with the
#    port, the cause and the fix, and DSH keeps running (its web port answers). The app shows
#    that another program uses the port.
# 3. The script stops that program. DSH runs, but its bridge did not start: the app shows that
#    nothing listens on the port.
#
#   scripts/demo/bridge-errors.sh           tests, then the UI tests on real DSH (Noise)
#   scripts/demo/bridge-errors.sh --shots   also refresh the screenshots in evidence/S8/ (1/3 size)
#   DSHM_RESUME=1                          skip the parts that passed for the same code (lib.sh demo_part)
#
# Resources (scripts/slice-env): DSHM_BRIDGE_PORT, DSHM_WEB_PORT, DSHM_HOME, DSHM_SIM, DSHM_DD.
# Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0
for a in "$@"; do case "$a" in --shots) SHOTS=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47800}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3283}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home}"
export DSHM_SIM="${DSHM_SIM:-iPhone 17 Pro}" DSHM_DD="${DSHM_DD:-/tmp/dshm-bridge-errors-dd}"
export PATH="$HOME/.dshm/bin:$HOME/.nvm/versions/node/v24.14.0/bin:$PATH"
step() { printf '\n== %s\n' "$*"; }
source scripts/demo/lib.sh
LOGS=/tmp/dshm-bridge-errors-$DSHM_BRIDGE_PORT; mkdir -p "$LOGS"
SIM="$DSHM_SIM"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
SHOT_DIR="$(mktemp -d)"
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR" TEST_RUNNER_DSHM_BRIDGE_PORT="$DSHM_BRIDGE_PORT"

DSH_PID=""; HOLDER_PID=""
stop() { if [ -n "$1" ]; then kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; fi; }
cleanup() { stop "$DSH_PID"; stop "$HOLDER_PID"; rm -rf "$SHOT_DIR"; }
trap cleanup EXIT
listening() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

demo_prepare_bridge
step "bridge tests: the listen error line (node:test)"
(cd bridge && corepack pnpm build >/dev/null)
demo_part bridge-errors-bridge-test node --test bridge/lib/test/listen-errors.test.js

step "DSHKit tests: the three reasons (swift test, fake and loopback sockets)"
demo_part bridge-errors-swift-test scripts/swift-test --package-path ios/DSHKit --filter OfflineReasonsTests

step "build the app and UI tests ($SIM)"
scripts/xc build-for-testing -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DSHM_DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  --log "$LOGS/build.log" || { grep -E "error:" "$LOGS/build.log"; exit 1; }

ui_part() { # name, then -only-testing selectors
  local name=$1; shift
  local args=() t
  for t in "$@"; do args+=("-only-testing:dsh-mobileUITests/$t"); done
  step "UI: $name (log: $LOGS/ui-$name.log)"
  if demo_part "ui-$name" scripts/xc test-without-building -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile \
      -destination "$DEST" -derivedDataPath "$DSHM_DD" -parallel-testing-enabled NO "${args[@]}" \
      --log "$LOGS/ui-$name.log"; then
    grep -E "Test Case.*(passed|failed|skipped)" "$LOGS/ui-$name.log" || true
  else
    grep -E "error:|Test Case.*(passed|failed)" "$LOGS/ui-$name.log" || tail -30 "$LOGS/ui-$name.log"
    echo "UI tests failed: $name" >&2
    exit 1
  fi
  demo_no_skipped_ui "$LOGS/ui-$name.log"
}

start_dsh() { # log file
  DSHM_BRIDGE_DEV_PLAINTEXT=0 node scripts/dsh-up.mjs > "$1" 2>&1 &
  DSH_PID=$!
}

if listening "$DSHM_BRIDGE_PORT"; then echo "port $DSHM_BRIDGE_PORT is in use" >&2; exit 1; fi
if listening "$DSHM_WEB_PORT"; then echo "port $DSHM_WEB_PORT is in use" >&2; exit 1; fi

step "1. real DSH + bridge with Noise only (web $DSHM_WEB_PORT, bridge $DSHM_BRIDGE_PORT, $DSHM_HOME)"
mkdir -p "$DSHM_HOME"
start_dsh "$LOGS/dsh-up.log"
for _ in $(seq 1 240); do listening "$DSHM_BRIDGE_PORT" && break; sleep 0.5; done
listening "$DSHM_BRIDGE_PORT" || { tail -20 "$LOGS/dsh-up.log"; echo "bridge did not come up" >&2; exit 1; }
for _ in $(seq 1 40); do [ -f "$DSHM_HOME/dsh-mobile-bridge/listener.json" ] && break; sleep 0.25; done
URL="$(DSH_HOME="$DSHM_HOME" node bridge/lib/scripts/pair.js --url-only)"
URL="$(node -e 'const u=new URL(process.argv[1]); u.searchParams.set("a", process.argv[2]); console.log(u.toString())' \
  "$URL" "127.0.0.1:$DSHM_BRIDGE_PORT")"
TEST_RUNNER_DSHM_BRIDGE_ERRORS_PAIR_URL="$URL" ui_part bridge-errors-pair OfflineReasonsUITests/testPairWhileTheBridgeListens

step "2. another program on port $DSHM_BRIDGE_PORT, then DSH again"
stop "$DSH_PID"; DSH_PID=""
for _ in $(seq 1 120); do listening "$DSHM_BRIDGE_PORT" || listening "$DSHM_WEB_PORT" || break; sleep 0.25; done
node scripts/demo/port-holder.mjs "$DSHM_BRIDGE_PORT" > "$LOGS/port-holder.log" 2>&1 &
HOLDER_PID=$!
for _ in $(seq 1 40); do grep -q 'port-holder: ready' "$LOGS/port-holder.log" && break; sleep 0.25; done
grep -q 'port-holder: ready' "$LOGS/port-holder.log" || { cat "$LOGS/port-holder.log"; echo "the port holder did not come up" >&2; exit 1; }
start_dsh "$LOGS/dsh-up-taken.log"
LINE="cannot listen on 127.0.0.1:$DSHM_BRIDGE_PORT"
for _ in $(seq 1 240); do grep -qF "$LINE" "$LOGS/dsh-up-taken.log" && break; sleep 0.5; done
grep -F "$LINE" "$LOGS/dsh-up-taken.log" || { tail -30 "$LOGS/dsh-up-taken.log"; echo "no listen error line in DSH's log" >&2; exit 1; }
COUNT=$(grep -cF "dsh-mobile-bridge cannot listen" "$LOGS/dsh-up-taken.log")
[ "$COUNT" = 1 ] || { echo "expected one listen error line, got $COUNT" >&2; exit 1; }
grep -F "$LINE" "$LOGS/dsh-up-taken.log" | grep -q "another program uses port $DSHM_BRIDGE_PORT (EADDRINUSE)" \
  || { echo "the line does not name the cause" >&2; exit 1; }
grep -F "$LINE" "$LOGS/dsh-up-taken.log" | grep -q "Fix: .*DSHM_BRIDGE_PORT" \
  || { echo "the line does not name the setting to change" >&2; exit 1; }
# DSH keeps running: its process lives and its web port answers.
sleep 2
kill -0 "$DSH_PID" 2>/dev/null || { tail -30 "$LOGS/dsh-up-taken.log"; echo "DSH stopped" >&2; exit 1; }
for _ in $(seq 1 120); do listening "$DSHM_WEB_PORT" && break; sleep 0.5; done
CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$DSHM_WEB_PORT/" || true)
[ "$CODE" != "000" ] || { echo "DSH's web port $DSHM_WEB_PORT does not answer" >&2; exit 1; }
echo "DSH keeps running: web port $DSHM_WEB_PORT answers HTTP $CODE; port $DSHM_BRIDGE_PORT still belongs to the port holder"
TEST_RUNNER_DSHM_BRIDGE_ERRORS_STEP=taken ui_part bridge-errors-taken OfflineReasonsUITests/testAnotherProgramOnTheBridgePort
cat "$LOGS/port-holder.log"

step "3. the other program stops; the bridge did not start: nothing listens on port $DSHM_BRIDGE_PORT"
stop "$HOLDER_PID"; HOLDER_PID=""
TEST_RUNNER_DSHM_BRIDGE_ERRORS_STEP=free ui_part bridge-errors-free OfflineReasonsUITests/testNothingListensOnTheBridgePort

if [ $SHOTS = 1 ]; then
  step "screenshots → evidence/S8 (1/3 size)"
  mkdir -p evidence/S8
  for f in "$SHOT_DIR"/bridge-errors-*.png; do
    [ -e "$f" ] || { echo "no new shots (the UI parts were skipped)"; break; }
    out="evidence/S8/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
step "bridge errors demo passed"
