#!/bin/bash
# Demo and checks, end to end.
#
#   scripts/demo/round-trip.sh             all checks + UI tests, including the real-DSH demo
#   scripts/demo/round-trip.sh --fake-only skip anything that needs DSH (CI-like)
#   scripts/demo/round-trip.sh --shots     also refresh the screenshots in evidence/round-trip/
#
# Real DSH: uses a bridge already listening on 127.0.0.1:${DSHM_BRIDGE_PORT:-47801}, or starts
# `node scripts/dsh-up.mjs` (DSH 0.2.2-rc.1 + DSH's mock LLM, no API key) and stops it afterwards.
# Simulator: $DSHM_SIM (name or UDID, default "iPhone 17 Pro"). DerivedData: $DSHM_DD (default
# /tmp/dshm-round-trip-dd). Node 24 from ~/.nvm if present. Fails on any failed or skipped test; with
# --fake-only the real-DSH test is left out rather than skipped.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
FAKE_ONLY=0; SHOTS=0
for a in "$@"; do case "$a" in --fake-only) FAKE_ONLY=1 ;; --shots) SHOTS=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
PORT="${DSHM_BRIDGE_PORT:-47801}"
SIM="${DSHM_SIM:-iPhone 17 Pro}"
NODE24="$HOME/.nvm/versions/node/v24.14.0/bin"
[ -d "$NODE24" ] && export PATH="$NODE24:$PATH"
[ -d "$HOME/.dshm/bin" ] && export PATH="$HOME/.dshm/bin:$PATH"
step() { printf '\n== %s\n' "$*"; }
source scripts/demo/lib.sh
demo_tls_home
LOGS="/tmp/dshm-t0-${DSHM_BRIDGE_PORT:-47801}"; mkdir -p "$LOGS"
DD="${DSHM_DD:-/tmp/dshm-round-trip-dd}"

demo_prepare_bridge

step "bridge tests (node:test, FakeDSH, golden fixtures)"
demo_bridge_tests "$LOGS/bridge-test.log"

step "DSHKit tests (swift test, FakeBridge, golden fixtures)"
demo_swift_tests "$LOGS/swift-test.log"

DSH_PID=""
cleanup() { [ -n "$DSH_PID" ] && kill "$DSH_PID" 2>/dev/null || true; }
trap cleanup EXIT
if [ $FAKE_ONLY = 0 ]; then
  if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "The assigned bridge port is in use" >&2
    exit 1
  fi
  step "starting real DSH + bridge (scripts/dsh-up.mjs)"
  (cd bridge && corepack pnpm build >/dev/null)
  node scripts/dsh-up.mjs > "$LOGS/dsh-up.log" 2>&1 &
  DSH_PID=$!
  for _ in $(seq 1 240); do lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.5; done
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null || { cat "$LOGS/dsh-up.log"; echo "bridge did not come up" >&2; exit 1; }
  step "bridge inside real DSH answers a CLI client"
  demo_tls_client "$DSHM_HOME" "$DSHM_HOME/cli.json" "用一句话介绍你自己。"
fi

step "UI tests in the Simulator ($SIM)"
SHOT_DIR="$(mktemp -d)"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR" TEST_RUNNER_DSHM_BRIDGE_PORT="$PORT"
ONLY=(-only-testing:dsh-mobileUITests/RoundTripUITests)
if [ $FAKE_ONLY = 0 ]; then export TEST_RUNNER_DSHM_REAL_DSH=1
else ONLY+=(-skip-testing:dsh-mobileUITests/RoundTripUITests/testDemoAgainstRealDSH); fi
demo_tls_ui test -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates "${ONLY[@]}" \
  --log "$LOGS/uitest.log" || { grep -E "error:|Test Case" "$LOGS/uitest.log"; exit 1; }
grep -E "Test Case.*(passed|failed|skipped)" "$LOGS/uitest.log"
demo_no_skipped_ui "$LOGS/uitest.log"

if [ $SHOTS = 1 ]; then
  step "screenshots → ${DSHM_EVIDENCE:-evidence/round-trip} (1/3 size)"
  mkdir -p ${DSHM_EVIDENCE:-evidence/round-trip}
  for f in "$SHOT_DIR"/*.png; do
    out="${DSHM_EVIDENCE:-evidence/round-trip}/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
step "round-trip demo passed"
