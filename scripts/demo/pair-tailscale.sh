#!/bin/bash
# Demo and checks: pair over Tailscale.
# The bug (2026-11-08, real iPhone 17 Pro): "couldn't reach the host at 30.34.227.222:47801,
# 100.79.171.34:47801". App Transport Security refused cleartext ws:// to IP addresses outside
# the local ranges (Tailscale 100.64/10, a public 30.x) before any packet left the phone.
#
#   scripts/demo/pair-tailscale.sh          PairTailscaleUITests on a real DSH + bridge bound to 0.0.0.0
#                                (its own ports, TLS). The pairing link keeps only the Mac's
#                                non-local IPv4 addresses (not 10/8, 172.16/12, 192.168/16,
#                                127/8, 169.254/16). Then swift test (DSHKit).
#   scripts/demo/pair-tailscale.sh --shots  also refresh the screenshots in evidence/pair-tailscale/ (1/3 size)
#   DSHM_RESUME=1               skip the parts that passed for the same code (lib.sh demo_part)
#
# Needs one non-local IPv4 address on this Mac (Tailscale's 100.x, or a public LAN address).
# Without one the demo fails: it cannot show the bug. The Simulator uses the Mac's network.
#
# Resources, read from the environment (scripts/slice-env):
#   DSHM_SIM dshm-pair-tailscale   DSHM_DD (DerivedData) /tmp/dshm-pair-tailscale-dd
#   DSHM_BRIDGE_PORT 47810, DSHM_WEB_PORT 3283, DSHM_HOME ~/.dshm/home-pair-tailscale
# Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0
for a in "$@"; do case "$a" in --shots) SHOTS=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
export DSHM_SIM="${DSHM_SIM:-dshm-pair-tailscale}" DSHM_DD="${DSHM_DD:-/tmp/dshm-pair-tailscale-dd}"
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47810}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3283}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home-pair-tailscale}"
NODE24="$HOME/.nvm/versions/node/v24.14.0/bin"
[ -d "$NODE24" ] && export PATH="$NODE24:$PATH"
[ -d "$HOME/.dshm/bin" ] && export PATH="$HOME/.dshm/bin:$PATH"
step() { printf '\n== %s\n' "$*"; }
source scripts/demo/lib.sh
demo_tls_home
LOGS="/tmp/dshm-s31-${DSHM_BRIDGE_PORT:-47801}"; mkdir -p "$LOGS"
SIM="$DSHM_SIM"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi

SHOT_DIR="$(mktemp -d)"
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR"

step "build the app and UI tests ($SIM)"
scripts/xc build-for-testing -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DSHM_DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  --log "$LOGS/build.log" || { grep -E "error:" "$LOGS/build.log"; exit 1; }

step "the built app's ATS keys (ARCHITECTURE.md)"
APP_PLIST="$(find "$DSHM_DD/Build/Products" -path '*iphonesimulator/dsh-mobile.app/Info.plist' | head -1)"
plutil -extract NSAppTransportSecurity json -o - "$APP_PLIST" 2>/dev/null || echo "(no NSAppTransportSecurity)"

ui_part() { # name, then -only-testing selectors
  local name=$1; shift
  local args=() t
  for t in "$@"; do args+=("-only-testing:dsh-mobileUITests/$t"); done
  step "UI: $name (log: $LOGS/ui-$name.log)"
  if demo_part "ui-$name" demo_tls_ui test-without-building -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile \
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

# Non-local IPv4 addresses of this Mac: what ATS does not treat as local networking.
non_local_ipv4() {
  ifconfig | awk '/inet / {print $2}' | grep -vE '^(127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.)' || true
}
ADDRS="$(non_local_ipv4 | sed "s/\$/:$DSHM_BRIDGE_PORT/" | paste -sd, -)"
[ -n "$ADDRS" ] || { echo "this Mac has no non-local IPv4 address (Tailscale 100.x or public); this demo cannot show the bug here" >&2; exit 1; }

DSH_PID=""
trap '[ -n "$DSH_PID" ] && kill "$DSH_PID" 2>/dev/null || true' EXIT
demo_prepare_bridge
(cd bridge && corepack pnpm build >/dev/null)

step "real DSH + bridge on 0.0.0.0 (web $DSHM_WEB_PORT, bridge $DSHM_BRIDGE_PORT, $DSHM_HOME)"
mkdir -p "$DSHM_HOME"
if lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null 2>&1; then echo "port $DSHM_BRIDGE_PORT is in use" >&2; exit 1; fi
DSHM_BRIDGE_HOST=0.0.0.0 node scripts/dsh-up.mjs > "$LOGS/dsh-up.log" 2>&1 &
DSH_PID=$!
for _ in $(seq 1 240); do lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.5; done
lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null || { tail -20 "$LOGS/dsh-up.log"; echo "bridge did not come up" >&2; exit 1; }
for _ in $(seq 1 40); do [ -f "$DSHM_HOME/dsh-mobile-bridge/listener.json" ] && break; sleep 0.25; done

# The link with only the non-local addresses (the `a` field of offerURL, bridge/src/pairing/offer.ts).
URL="$(DSH_HOME="$DSHM_HOME" node bridge/lib/scripts/pair.js --url-only)"
URL="$(node -e 'const u=new URL(process.argv[1]); u.searchParams.set("a", process.argv[2]); console.log(u.toString())' "$URL" "$ADDRS")"
echo "pairing addresses: $ADDRS"
TEST_RUNNER_DSHM_TAILSCALE_PAIR_URL="$URL" ui_part pair-tailscale-real PairTailscaleUITests/testPairAndConnectThroughANonLocalAddress
kill "$DSH_PID" 2>/dev/null || true; wait "$DSH_PID" 2>/dev/null || true; DSH_PID=""

step "DSHKit tests (swift test, FakeBridge)"
demo_part pair-tailscale-swift-test bash -c 'source scripts/demo/lib.sh; demo_swift_tests "$1"' _ "$LOGS/swift-test.log"

if [ $SHOTS = 1 ]; then
  step "screenshots → ${DSHM_EVIDENCE:-evidence/pair-tailscale} (1/3 size)"
  mkdir -p ${DSHM_EVIDENCE:-evidence/pair-tailscale}
  for f in "$SHOT_DIR"/pair-tailscale-*.png; do
    [ -e "$f" ] || { echo "no new shots (the UI part was skipped)"; break; }
    out="${DSHM_EVIDENCE:-evidence/pair-tailscale}/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
step "pair-tailscale demo passed"
