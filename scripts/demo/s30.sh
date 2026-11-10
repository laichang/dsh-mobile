#!/bin/bash
# S30 demo and checks: pair the same host again after a revoke.
# The bug (2026-11-08, real iPhone): after a revoke of this phone, 08 asked to pair again; the
# user scanned a fresh QR from the same Mac, pairing succeeded, and then the root showed
# "Couldn't open your paired computers". The app kept the forgotten host's key in memory and
# dropped the same Mac (same host key, same `noise:<host id>`) from the new store.
#
#   scripts/demo/s30.sh          S30PairAgainUITests on a real DSH + bridge (scripts/dsh-up.mjs on
#                                S30's ports, Noise, three fresh pairing links: pair, revoke this
#                                device in X2, 08, pair again, drawer; revoke again, pair again),
#                                then S29's checks so its behaviour stays: S29RevokeUITests on the
#                                fakes and on a real bridge (S30's second ports), S21's revoke seam,
#                                and swift test (DSHKit)
#   scripts/demo/s30.sh --shots  also refresh the screenshots in evidence/S30/ (1/3 size)
#   DSHM_RESUME=1               skip the parts that passed for the same code (lib.sh demo_part)
#
# Resources (WORKFLOW.md §6), read from the environment:
#   DSHM_SIM dshm-S30   DSHM_DD (DerivedData) /tmp/dshm-s30-dd
#   DSHM_BRIDGE_PORT 47810, DSHM_WEB_PORT 3283, DSHM_HOME ~/.dshm/home-s30: S30's real host
#   DSHM_SECOND_BRIDGE_PORT 47840, DSHM_SECOND_WEB_PORT 3313: the host of S29's real-bridge tests
# Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0
for a in "$@"; do case "$a" in --shots) SHOTS=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
export DSHM_SIM="${DSHM_SIM:-dshm-S30}" DSHM_DD="${DSHM_DD:-/tmp/dshm-s30-dd}"
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47810}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3283}"
export DSHM_SECOND_BRIDGE_PORT="${DSHM_SECOND_BRIDGE_PORT:-47840}" DSHM_SECOND_WEB_PORT="${DSHM_SECOND_WEB_PORT:-3313}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home-s30}"
NODE24="$HOME/.nvm/versions/node/v24.14.0/bin"
[ -d "$NODE24" ] && export PATH="$NODE24:$PATH"
[ -d "$HOME/.dshm/bin" ] && export PATH="$HOME/.dshm/bin:$PATH"
step() { printf '\n== %s\n' "$*"; }
source scripts/demo/lib.sh
LOGS=/tmp/dshm-s30; mkdir -p "$LOGS"
SIM="$DSHM_SIM"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi

SHOT_DIR="$(mktemp -d)"
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR"

step "build the app and UI tests ($SIM)"
scripts/xc build-for-testing -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DSHM_DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  --log "$LOGS/build.log" || { grep -E "error:" "$LOGS/build.log"; exit 1; }

# One part per UI test group (lib.sh demo_part): a failure in one does not run the others again.
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

# A real DSH + bridge on the given ports and home. Sets DSH_PID.
DSH_PID=""
trap '[ -n "$DSH_PID" ] && kill "$DSH_PID" 2>/dev/null || true' EXIT
start_host() { # bridge port, web port, home
  mkdir -p "$3"
  if lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; then echo "port $1 is in use" >&2; exit 1; fi
  DSHM_BRIDGE_PORT="$1" DSHM_WEB_PORT="$2" DSHM_HOME="$3" node scripts/dsh-up.mjs > "$LOGS/dsh-up-$1.log" 2>&1 &
  DSH_PID=$!
  for _ in $(seq 1 240); do lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.5; done
  lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null || { tail -20 "$LOGS/dsh-up-$1.log"; echo "bridge did not come up" >&2; exit 1; }
  for _ in $(seq 1 40); do [ -f "$3/dsh-mobile-bridge/listener.json" ] && break; sleep 0.25; done
}
stop_host() { kill "$DSH_PID" 2>/dev/null || true; wait "$DSH_PID" 2>/dev/null || true; DSH_PID=""; }
pair_url() { DSH_HOME="$1" node bridge/lib/scripts/pair.js --url-only; }

demo_prepare_bridge
(cd bridge && corepack pnpm build >/dev/null)

step "real DSH + bridge (web $DSHM_WEB_PORT, bridge $DSHM_BRIDGE_PORT, $DSHM_HOME)"
start_host "$DSHM_BRIDGE_PORT" "$DSHM_WEB_PORT" "$DSHM_HOME"
TEST_RUNNER_DSHM_S30_PAIR_URL="$(pair_url "$DSHM_HOME")" TEST_RUNNER_DSHM_S30_PAIR_URL_2="$(pair_url "$DSHM_HOME")" \
TEST_RUNNER_DSHM_S30_PAIR_URL_3="$(pair_url "$DSHM_HOME")" \
  ui_part s30-real S30PairAgainUITests/testPairTheSameHostAgainAfterARevokeOpensTheDrawer
stop_host

# S29 stays green: a revoked host leaves the drawer, is not retried, and the alert wording.
ui_part s29 S29RevokeUITests/testRevokedHostLeavesTheDrawerAndIsNotRetried S29RevokeUITests/testRevokedLastHostOpens08
S29_HOME="$DSHM_HOME/s29"
step "S29 on a real DSH + bridge (web $DSHM_SECOND_WEB_PORT, bridge $DSHM_SECOND_BRIDGE_PORT, $S29_HOME)"
start_host "$DSHM_SECOND_BRIDGE_PORT" "$DSHM_SECOND_WEB_PORT" "$S29_HOME"
TEST_RUNNER_DSHM_S29_PAIR_URL="$(pair_url "$S29_HOME")" TEST_RUNNER_DSHM_S29_PAIR_URL_2="$(pair_url "$S29_HOME")" \
  ui_part s29-real S29RevokeUITests/testRevokeThisDeviceInHostsSheetOnTheRealBridgeOpens08AndStays \
    S29RevokeUITests/testRevokeThisDeviceInDrawerDevicesOnTheRealBridgeOpens08AndStays
stop_host
ui_part s21-seam S21HostsUITests/testRevokeThisDeviceAsksThenOpens08

step "DSHKit tests (swift test, FakeBridge)"
demo_part s30-swift-test bash -c 'source scripts/demo/lib.sh; demo_swift_tests "$1"' _ "$LOGS/swift-test.log"

if [ $SHOTS = 1 ]; then
  step "screenshots → evidence/S30 (1/3 size)"
  mkdir -p evidence/S30
  for f in "$SHOT_DIR"/s30-*.png; do
    [ -e "$f" ] || { echo "no new shots (the UI part was skipped)"; break; }
    out="evidence/S30/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
step "S30 demo passed"
