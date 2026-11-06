#!/bin/bash
# S22 demo and checks: first run (PLAN.md §5 S22, DESIGN.md screen 08, STORY §6).
# A fresh Release install on the slice simulator, a real DSH with the bridge (scripts/dsh-up.mjs,
# Noise only), and a pairing link from bridge/lib/scripts/pair.js. The UI test pastes the link on
# 08, pairs, and checks that 01 opens with the first task in the composer, edits it, and sends it.
#
#   scripts/demo/s22.sh          bridge build, Release build, S22FirstRunUITests, and the seam:
#                                scripts/demo/s11.sh (its end-to-end test now finds the first task
#                                already in the composer, D63)
#   scripts/demo/s22.sh --shots  also refresh the screenshots in evidence/S22/ (1/3 size)
#
# Resources (WORKFLOW.md §6), read from the environment (`eval "$(scripts/slice-env S22)"`):
#   DSHM_SIM dshm-S22   DSHM_BRIDGE_PORT 47810   DSHM_WEB_PORT 3283   DSHM_HOME ~/.dshm/home-s22
#   DSHM_DD (DerivedData) /tmp/dshm-s22-dd
# Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0 PART=""
for a in "$@"; do
  case "$a" in
    --shots) SHOTS=1 ;;
    --ui-part) PART=ui ;;
    *) echo "unknown arg $a" >&2; exit 2 ;;
  esac
done
export DSHM_SIM="${DSHM_SIM:-dshm-S22}" DSHM_DD="${DSHM_DD:-/tmp/dshm-s22-dd}"
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47810}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3283}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home-s22}"
export PATH="$HOME/.dshm/bin:$HOME/.nvm/versions/node/v24.14.0/bin:$PATH"
SIM="$DSHM_SIM"
LOGS=/tmp/dshm-s22
mkdir -p "$LOGS" "$DSHM_HOME"
step() { printf '\n== %s\n' "$*"; }
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
args=(-project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -configuration Release -destination "$DEST"
      -derivedDataPath "$DSHM_DD" -parallel-testing-enabled NO ONLY_ACTIVE_ARCH=YES
      -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates)

# The UI part (run through demo_part below): fresh install, a real host, the S22 UI test.
if [ "$PART" = ui ]; then
  PROFILE=$(mktemp -d "$DSHM_HOME/first-run.XXXXXX")
  host_pid=""
  cleanup() {
    if [ -n "$host_pid" ]; then kill "$host_pid" 2>/dev/null || true; wait "$host_pid" || true; fi
    rm -rf "$PROFILE"
  }
  trap cleanup EXIT
  xcrun simctl bootstatus "$SIM" -b >/dev/null
  if xcrun simctl get_app_container "$SIM" chang.dsh-mobile app >/dev/null 2>&1; then
    xcrun simctl uninstall "$SIM" chang.dsh-mobile
  fi
  if lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null; then echo "S22 bridge port is busy" >&2; exit 1; fi
  DSHM_HOME="$PROFILE" DSHM_BRIDGE_DEV_PLAINTEXT=0 node scripts/dsh-up.mjs > "$LOGS/host.log" 2>&1 &
  host_pid=$!
  for _ in $(seq 1 180); do
    lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null && break
    kill -0 "$host_pid" 2>/dev/null || { tail -10 "$LOGS/host.log"; exit 1; }
    sleep 0.5
  done
  lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null || { echo "S22 host did not start" >&2; exit 1; }
  TEST_RUNNER_DSHM_PAIR_URL="$(DSH_HOME="$PROFILE" node bridge/lib/scripts/pair.js --url-only)"
  export TEST_RUNNER_DSHM_PAIR_URL TEST_RUNNER_DSHM_SHOT_DIR="$S22_SHOT_DIR"
  log="$LOGS/ui.log"
  xcodebuild test-without-building "${args[@]}" -only-testing:dsh-mobileUITests/S22FirstRunUITests \
    > "$log" 2>&1 || { grep -E 'error:|Test Case' "$log" | tail -20; exit 1; }
  grep -E "Test Case.*(passed|failed|skipped)" "$log"
  source scripts/demo/lib.sh
  demo_no_skipped_ui "$log"
  exit 0
fi

source scripts/demo/lib.sh

step "bridge build (pnpm install, codegen check, tsc)"
demo_prepare_bridge
(cd bridge && corepack pnpm exec tsc -p .) > "$LOGS/tsc.log" 2>&1 || { tail -20 "$LOGS/tsc.log"; exit 1; }

step "Release build of the app and UI tests ($SIM)"
xcodebuild build-for-testing "${args[@]}" > "$LOGS/build.log" 2>&1 \
  || { grep -E 'error:|failed' "$LOGS/build.log" | tail -20; exit 1; }

S22_SHOT_DIR="$(mktemp -d)"
export S22_SHOT_DIR
step "UI: fresh install, paste a pairing link on 08, 01 opens with the first task (S22)"
# demo_part (lib.sh): with DSHM_RESUME=1 or on a retry in scripts/review, a part that passed for
# the same code does not run again.
demo_part s22-ui "$0" --ui-part

step "seam: S11's first run (scripts/demo/s11.sh on the S22 resources)"
demo_part s22-seam-s11 scripts/demo/s11.sh

if [ $SHOTS = 1 ]; then
  step "screenshots → evidence/S22 (1/3 size)"
  mkdir -p evidence/S22
  for f in "$S22_SHOT_DIR"/s22-*.png; do
    [ -e "$f" ] || { echo "no new shots (the UI part was skipped)"; break; }
    out="evidence/S22/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
rm -rf "$S22_SHOT_DIR"
step "S22 demo passed"
