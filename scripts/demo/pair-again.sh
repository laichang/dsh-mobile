#!/bin/bash
# Demo and checks: pair the same host again after a revoke.
# The bug (2026-11-08, real iPhone): after a revoke of this phone, 08 asked to pair again; the
# user scanned a fresh QR from the same Mac, pairing succeeded, and then the root showed
# "Couldn't open your paired computers". The app kept the forgotten host's key in memory and
# dropped the same Mac (same host key, same `noise:<host id>`) from the new store.
#
#   scripts/demo/pair-again.sh          PairAgainUITests on a real DSH + bridge (scripts/dsh-up.mjs on
#                                its own ports, Noise, three fresh pairing links: pair, revoke this
#                                device in X2, 08, pair again, drawer; revoke again, pair again),
#                                then the revoke checks so its behaviour stays: RevokeUITests on the
#                                fakes and on a real bridge (its second ports), the hosts sheet revoke seam,
#                                and swift test (DSHKit)
#   scripts/demo/pair-again.sh --shots  also refresh the screenshots in evidence/pair-again/ (1/3 size)
#   DSHM_RESUME=1               skip the parts that passed for the same code (lib.sh demo_part)
#
# Resources (WORKFLOW.md §6), read from the environment:
#   DSHM_SIM dshm-pair-again   DSHM_DD (DerivedData) /tmp/dshm-pair-again-dd
#   DSHM_BRIDGE_PORT 47810, DSHM_WEB_PORT 3283, DSHM_HOME ~/.dshm/home-pair-again: its real host
#   DSHM_SECOND_BRIDGE_PORT 47840, DSHM_SECOND_WEB_PORT 3313: the host of the revoke real-bridge tests
# Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0
for a in "$@"; do case "$a" in --shots) SHOTS=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
export DSHM_SIM="${DSHM_SIM:-dshm-pair-again}" DSHM_DD="${DSHM_DD:-/tmp/dshm-pair-again-dd}"
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47810}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3283}"
export DSHM_SECOND_BRIDGE_PORT="${DSHM_SECOND_BRIDGE_PORT:-47840}" DSHM_SECOND_WEB_PORT="${DSHM_SECOND_WEB_PORT:-3313}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home-pair-again}"
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
TEST_RUNNER_DSHM_PAIR_AGAIN_URL="$(pair_url "$DSHM_HOME")" TEST_RUNNER_DSHM_PAIR_AGAIN_URL_2="$(pair_url "$DSHM_HOME")" \
TEST_RUNNER_DSHM_PAIR_AGAIN_URL_3="$(pair_url "$DSHM_HOME")" \
  ui_part pair-again-real PairAgainUITests/testPairTheSameHostAgainAfterARevokeOpensTheDrawer
stop_host

# Revoke stays green: a revoked host leaves the drawer, is not retried, and the alert wording.
ui_part s29 RevokeUITests/testRevokedHostLeavesTheDrawerAndIsNotRetried RevokeUITests/testRevokedLastHostOpens08
REVOKE_HOME="$DSHM_HOME/s29"
step "Revoke on a real DSH + bridge (web $DSHM_SECOND_WEB_PORT, bridge $DSHM_SECOND_BRIDGE_PORT, $REVOKE_HOME)"
start_host "$DSHM_SECOND_BRIDGE_PORT" "$DSHM_SECOND_WEB_PORT" "$REVOKE_HOME"
TEST_RUNNER_DSHM_REVOKE_PAIR_URL="$(pair_url "$REVOKE_HOME")" TEST_RUNNER_DSHM_REVOKE_PAIR_URL_2="$(pair_url "$REVOKE_HOME")" \
  ui_part revoke-real RevokeUITests/testRevokeThisDeviceInHostsSheetOnTheRealBridgeOpens08AndStays \
    RevokeUITests/testRevokeThisDeviceInDrawerDevicesOnTheRealBridgeOpens08AndStays
stop_host
ui_part hosts-sheet-seam HostsUITests/testRevokeThisDeviceAsksThenOpens08

step "DSHKit tests (swift test, FakeBridge)"
demo_part pair-again-swift-test bash -c 'source scripts/demo/lib.sh; demo_swift_tests "$1"' _ "$LOGS/swift-test.log"

if [ $SHOTS = 1 ]; then
  step "screenshots → ${DSHM_EVIDENCE:-evidence/pair-again} (1/3 size)"
  mkdir -p ${DSHM_EVIDENCE:-evidence/pair-again}
  for f in "$SHOT_DIR"/pair-again-*.png; do
    [ -e "$f" ] || { echo "no new shots (the UI part was skipped)"; break; }
    out="${DSHM_EVIDENCE:-evidence/pair-again}/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
step "pair-again demo passed"
