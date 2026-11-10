#!/bin/bash
# Demo and checks: a host that revoked this phone.
# The bug (2026-11-08, real iPhone): after a revoke, the host stayed in the drawer and showed
# "connecting" every few seconds. Now a close 4003 (device unknown) is final: the app forgets
# the host, says so once, and shows 08 (no host left) or 01 with the other hosts.
# The fake parts use in-process `FakeHosts`, which close with 4003 like the bridge. One part
# runs the user's path on a real DSH + bridge (scripts/dsh-up.mjs on its own ports, Noise).
#
#   scripts/demo/revoke.sh          swift test (RevokedHostTests and the rest of DSHKit),
#                                RevokeUITests on the fakes, then on the real bridge (pair,
#                                revoke this device in X2, and in the drawer's "Devices and
#                                audit"; 08 stays), and the seams:
#                                HostsUITests/testRevokeThisDeviceAsksThenOpens08 (X2) and
#                                scripts/demo/devices.sh (DevicesUITests: revoke another device on
#                                a real bridge; it is refused with 4003), on its second ports
#   scripts/demo/revoke.sh --shots  also refresh the screenshots in evidence/revoke/ (1/3 size)
#   DSHM_RESUME=1               skip the parts that passed for the same code (lib.sh demo_part)
#
# Resources (WORKFLOW.md §6), read from the environment:
#   DSHM_SIM dshm-revoke   DSHM_DD (DerivedData) /tmp/dshm-revoke-dd
#   DSHM_BRIDGE_PORT 47812, DSHM_WEB_PORT 3285, DSHM_HOME ~/.dshm/home-revoke: the real host
#   DSHM_SECOND_BRIDGE_PORT 47842, DSHM_SECOND_WEB_PORT 3315: the devices seam's host
# Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0
for a in "$@"; do case "$a" in --shots) SHOTS=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
export DSHM_SIM="${DSHM_SIM:-dshm-revoke}" DSHM_DD="${DSHM_DD:-/tmp/dshm-revoke-dd}"
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47812}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3285}"
export DSHM_SECOND_BRIDGE_PORT="${DSHM_SECOND_BRIDGE_PORT:-47842}" DSHM_SECOND_WEB_PORT="${DSHM_SECOND_WEB_PORT:-3315}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home-revoke}"
NODE24="$HOME/.nvm/versions/node/v24.14.0/bin"
[ -d "$NODE24" ] && export PATH="$NODE24:$PATH"
[ -d "$HOME/.dshm/bin" ] && export PATH="$HOME/.dshm/bin:$PATH"
step() { printf '\n== %s\n' "$*"; }
source scripts/demo/lib.sh
LOGS=/tmp/dshm-s29; mkdir -p "$LOGS"
SIM="$DSHM_SIM"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi

step "DSHKit tests (swift test, FakeBridge; RevokedHostTests)"
demo_part revoke-swift-test bash -c 'source scripts/demo/lib.sh; demo_swift_tests "$1"' _ "$LOGS/swift-test.log"

SHOT_DIR="$(mktemp -d)"
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR"

step "build the app and UI tests ($SIM)"
scripts/xc build-for-testing -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DSHM_DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  --log "$LOGS/build.log" || { grep -E "error:" "$LOGS/build.log"; exit 1; }

# One part per UI test class (lib.sh demo_part): a failure in one does not run the others again.
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

ui_part s29 RevokeUITests/testRevokedHostLeavesTheDrawerAndIsNotRetried RevokeUITests/testRevokedLastHostOpens08

# The user's path on a real DSH + bridge: the bridge answers the revoke, then closes with 4003.
DSH_PID=""
trap '[ -n "$DSH_PID" ] && kill "$DSH_PID" 2>/dev/null || true' EXIT
real_bridge() {
  mkdir -p "$DSHM_HOME"
  demo_prepare_bridge
  (cd bridge && corepack pnpm build >/dev/null)
  if lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "port $DSHM_BRIDGE_PORT is in use" >&2; return 1
  fi
  node scripts/dsh-up.mjs > "$LOGS/dsh-up.log" 2>&1 &
  DSH_PID=$!
  for _ in $(seq 1 240); do lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.5; done
  lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null || { tail -20 "$LOGS/dsh-up.log"; echo "bridge did not come up" >&2; exit 1; }
  for _ in $(seq 1 40); do [ -f "$DSHM_HOME/dsh-mobile-bridge/listener.json" ] && break; sleep 0.25; done
  local pair="node bridge/lib/scripts/pair.js --url-only"
  TEST_RUNNER_DSHM_REVOKE_PAIR_URL="$(DSH_HOME="$DSHM_HOME" $pair)" TEST_RUNNER_DSHM_REVOKE_PAIR_URL_2="$(DSH_HOME="$DSHM_HOME" $pair)" \
    ui_part revoke-real RevokeUITests/testRevokeThisDeviceInHostsSheetOnTheRealBridgeOpens08AndStays \
      RevokeUITests/testRevokeThisDeviceInDrawerDevicesOnTheRealBridgeOpens08AndStays
  kill "$DSH_PID" 2>/dev/null || true; wait "$DSH_PID" 2>/dev/null || true; DSH_PID=""
}
step "real DSH + bridge (web $DSHM_WEB_PORT, bridge $DSHM_BRIDGE_PORT, $DSHM_HOME)"
real_bridge

# The seams: the revoke of this device from X2 (the fake now closes with 4003 after the
# response), and the devices demo's revoke of another device on a real bridge (its second ports).
# Only the hosts sheet revoke test: scripts/demo/hosts.sh runs the other hosts sheet tests.
ui_part hosts-sheet-seam HostsUITests/testRevokeThisDeviceAsksThenOpens08
step "seam: scripts/demo/devices.sh (log: $LOGS/devices.log)"
demo_part devices-seam env DSHM_BRIDGE_PORT="$DSHM_SECOND_BRIDGE_PORT" DSHM_WEB_PORT="$DSHM_SECOND_WEB_PORT" \
  DSHM_HOME="$DSHM_HOME/devices" scripts/demo/devices.sh > "$LOGS/devices.log" 2>&1 \
  || { tail -30 "$LOGS/devices.log"; echo "devices seam failed" >&2; exit 1; }
tail -3 "$LOGS/devices.log"

if [ $SHOTS = 1 ]; then
  step "screenshots → ${DSHM_EVIDENCE:-evidence/revoke} (1/3 size)"
  mkdir -p ${DSHM_EVIDENCE:-evidence/revoke}
  for f in "$SHOT_DIR"/revoke-*.png; do
    [ -e "$f" ] || { echo "no new shots (the UI part was skipped)"; break; }
    out="${DSHM_EVIDENCE:-evidence/revoke}/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
step "revoke demo passed"
