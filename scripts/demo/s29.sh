#!/bin/bash
# S29 demo and checks: a host that revoked this phone (PLAN.md §5 S29, ARCHITECTURE D59, D82).
# The bug (2026-11-08, real iPhone): after a revoke, the host stayed in the drawer and showed
# "connecting" every few seconds. Now a close 4003 (device unknown) is final: the app forgets
# the host, says so once, and shows 08 (no host left) or 01 with the other hosts.
# The fake parts use in-process `FakeHosts`, which close with 4003 like the bridge. One part
# runs the user's path on a real DSH + bridge (scripts/dsh-up.mjs on S29's ports, Noise).
#
#   scripts/demo/s29.sh          swift test (RevokedHostTests and the rest of DSHKit),
#                                S29RevokeUITests on the fakes, then on the real bridge (pair,
#                                revoke this device in X2, and in the drawer's "Devices and
#                                audit"; 08 stays), and the seams:
#                                S21HostsUITests/testRevokeThisDeviceAsksThenOpens08 (X2) and
#                                scripts/demo/s10.sh (S10DevicesUITests: revoke another device on
#                                a real bridge; it is refused with 4003), on S29's second ports
#   scripts/demo/s29.sh --shots  also refresh the screenshots in evidence/S29/ (1/3 size)
#   DSHM_RESUME=1               skip the parts that passed for the same code (lib.sh demo_part)
#
# Resources (WORKFLOW.md §6), read from the environment:
#   DSHM_SIM dshm-S29   DSHM_DD (DerivedData) /tmp/dshm-s29-dd
#   DSHM_BRIDGE_PORT 47812, DSHM_WEB_PORT 3285, DSHM_HOME ~/.dshm/home-s29: the real host
#   DSHM_SECOND_BRIDGE_PORT 47842, DSHM_SECOND_WEB_PORT 3315: the S10 seam's host
# Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0
for a in "$@"; do case "$a" in --shots) SHOTS=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
export DSHM_SIM="${DSHM_SIM:-dshm-S29}" DSHM_DD="${DSHM_DD:-/tmp/dshm-s29-dd}"
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47812}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3285}"
export DSHM_SECOND_BRIDGE_PORT="${DSHM_SECOND_BRIDGE_PORT:-47842}" DSHM_SECOND_WEB_PORT="${DSHM_SECOND_WEB_PORT:-3315}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home-s29}"
NODE24="$HOME/.nvm/versions/node/v24.14.0/bin"
[ -d "$NODE24" ] && export PATH="$NODE24:$PATH"
[ -d "$HOME/.dshm/bin" ] && export PATH="$HOME/.dshm/bin:$PATH"
step() { printf '\n== %s\n' "$*"; }
source scripts/demo/lib.sh
LOGS=/tmp/dshm-s29; mkdir -p "$LOGS"
SIM="$DSHM_SIM"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi

step "DSHKit tests (swift test, FakeBridge; RevokedHostTests is S29's)"
demo_part s29-swift-test bash -c 'source scripts/demo/lib.sh; demo_swift_tests "$1"' _ "$LOGS/swift-test.log"

SHOT_DIR="$(mktemp -d)"
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR"

step "build the app and UI tests ($SIM)"
xcodebuild build-for-testing -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DSHM_DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  > "$LOGS/build.log" 2>&1 || { grep -E "error:" "$LOGS/build.log"; exit 1; }

# One part per UI test class (lib.sh demo_part): a failure in one does not run the others again.
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

ui_part s29 S29RevokeUITests/testRevokedHostLeavesTheDrawerAndIsNotRetried S29RevokeUITests/testRevokedLastHostOpens08

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
  TEST_RUNNER_DSHM_S29_PAIR_URL="$(DSH_HOME="$DSHM_HOME" $pair)" TEST_RUNNER_DSHM_S29_PAIR_URL_2="$(DSH_HOME="$DSHM_HOME" $pair)" \
    ui_part s29-real S29RevokeUITests/testRevokeThisDeviceInHostsSheetOnTheRealBridgeOpens08AndStays \
      S29RevokeUITests/testRevokeThisDeviceInDrawerDevicesOnTheRealBridgeOpens08AndStays
  kill "$DSH_PID" 2>/dev/null || true; wait "$DSH_PID" 2>/dev/null || true; DSH_PID=""
}
step "real DSH + bridge (web $DSHM_WEB_PORT, bridge $DSHM_BRIDGE_PORT, $DSHM_HOME)"
real_bridge

# The seams: the revoke of this device from X2 (the fake now closes with 4003 after the
# response), and S10's revoke of another device on a real bridge (S29's second ports).
# Only S21's revoke test: scripts/demo/hosts.sh runs the other S21 tests.
ui_part s21-seam S21HostsUITests/testRevokeThisDeviceAsksThenOpens08
step "seam: scripts/demo/s10.sh (log: $LOGS/s10.log)"
demo_part s10-seam env DSHM_BRIDGE_PORT="$DSHM_SECOND_BRIDGE_PORT" DSHM_WEB_PORT="$DSHM_SECOND_WEB_PORT" \
  DSHM_HOME="$DSHM_HOME/s10" scripts/demo/s10.sh > "$LOGS/s10.log" 2>&1 \
  || { tail -30 "$LOGS/s10.log"; echo "S10 seam failed" >&2; exit 1; }
tail -3 "$LOGS/s10.log"

if [ $SHOTS = 1 ]; then
  step "screenshots → evidence/S29 (1/3 size)"
  mkdir -p evidence/S29
  for f in "$SHOT_DIR"/s29-*.png; do
    [ -e "$f" ] || { echo "no new shots (the UI part was skipped)"; break; }
    out="evidence/S29/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
step "S29 demo passed"
