#!/bin/bash
# Demo and checks: first run (design screen 08, STORY §6).
# A fresh Release install on the slice simulator, a real DSH with the bridge (scripts/dsh-up.mjs,
# TLS), and a pairing link from bridge/lib/scripts/pair.js. The UI test pastes the link on
# 08, pairs, and checks that 01 opens with the first task in the composer, edits it, and sends it.
#
#   scripts/demo/first-run.sh          bridge build, Release build, FirstRunUITests, and the seam:
#                                scripts/demo/first-run-release.sh (its end-to-end test now finds the first task
#                                already in the composer)
#   scripts/demo/first-run.sh --shots  also refresh the screenshots in evidence/first-run/ (1/3 size)
#
# Resources, read from the environment (`eval "$(scripts/slice-env <ID>)"`):
#   DSHM_SIM dshm-first-run   DSHM_BRIDGE_PORT 47810   DSHM_WEB_PORT 3283   DSHM_HOME ~/.dshm/home-first-run
#   DSHM_DD (DerivedData) /tmp/dshm-first-run-dd
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
export DSHM_SIM="${DSHM_SIM:-dshm-first-run}" DSHM_DD="${DSHM_DD:-/tmp/dshm-first-run-dd}"
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47810}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3283}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home-first-run}"
export PATH="$HOME/.dshm/bin:$HOME/.nvm/versions/node/v24.14.0/bin:$PATH"
SIM="$DSHM_SIM"
LOGS="/tmp/dshm-s22-${DSHM_BRIDGE_PORT:-47801}"
mkdir -p "$LOGS" "$DSHM_HOME"
step() { printf '\n== %s\n' "$*"; }
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
args=(-project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -configuration Release -destination "$DEST"
      -derivedDataPath "$DSHM_DD" -parallel-testing-enabled NO ONLY_ACTIVE_ARCH=YES
      -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates)

# The UI part (run through demo_part below): fresh install, a real host, the first run UI test.
source scripts/demo/lib.sh
demo_tls_home
if [ "$PART" = ui ]; then
  PROFILE=$(mktemp -d "$DSHM_HOME/first-run.XXXXXX")
  host_pid=""
  cleanup() {
    if [ -n "$host_pid" ]; then kill "$host_pid" 2>/dev/null || true; wait "$host_pid" || true; fi
    rm -rf "$PROFILE"
  }
  demo_tls_on_exit cleanup
  xcrun simctl bootstatus "$SIM" -b >/dev/null
  if xcrun simctl get_app_container "$SIM" chang.dsh-mobile app >/dev/null 2>&1; then
    xcrun simctl uninstall "$SIM" chang.dsh-mobile
  fi
  if lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null; then echo "first run bridge port is busy" >&2; exit 1; fi
  DSHM_HOME="$PROFILE" node scripts/dsh-up.mjs > "$LOGS/host.log" 2>&1 &
  host_pid=$!
  for _ in $(seq 1 180); do
    lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null && break
    kill -0 "$host_pid" 2>/dev/null || { tail -10 "$LOGS/host.log"; exit 1; }
    sleep 0.5
  done
  lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null || { echo "first run host did not start" >&2; exit 1; }
  TEST_RUNNER_DSHM_PAIR_URL="$(DSH_HOME="$PROFILE" node bridge/lib/scripts/pair.js --url-only)"
  export TEST_RUNNER_DSHM_PAIR_URL TEST_RUNNER_DSHM_SHOT_DIR="$FIRST_RUN_SHOT_DIR"
  log="$LOGS/ui.log"
  demo_tls_ui test-without-building "${args[@]}" -only-testing:dsh-mobileUITests/FirstRunUITests \
    --log "$log" || { grep -E 'error:|Test Case' "$log" | tail -20; exit 1; }
  grep -E "Test Case.*(passed|failed|skipped)" "$log"
  demo_no_skipped_ui "$log"
  exit 0
fi

step "bridge build (pnpm install, codegen check, tsc)"
demo_prepare_bridge
(cd bridge && corepack pnpm exec tsc -p .) > "$LOGS/tsc.log" 2>&1 || { tail -20 "$LOGS/tsc.log"; exit 1; }

step "Release build of the app and UI tests ($SIM)"
scripts/xc build-for-testing "${args[@]}" --log "$LOGS/build.log" \
  || { grep -E 'error:|failed' "$LOGS/build.log" | tail -20; exit 1; }

FIRST_RUN_SHOT_DIR="$(mktemp -d)"
export FIRST_RUN_SHOT_DIR
step "UI: fresh install, paste a pairing link on 08, 01 opens with the first task "
# demo_part (lib.sh): with DSHM_RESUME=1 or on a retry in scripts/review, a part that passed for
# the same code does not run again.
demo_part first-run-ui "$0" --ui-part

step "seam: the Release first run (scripts/demo/first-run-release.sh on these resources)"
demo_part first-run-seam-s11 scripts/demo/first-run-release.sh

if [ $SHOTS = 1 ]; then
  step "screenshots → ${DSHM_EVIDENCE:-evidence/first-run} (1/3 size)"
  mkdir -p ${DSHM_EVIDENCE:-evidence/first-run}
  for f in "$FIRST_RUN_SHOT_DIR"/first-run-*.png; do
    [ -e "$f" ] || { echo "no new shots (the UI part was skipped)"; break; }
    out="${DSHM_EVIDENCE:-evidence/first-run}/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
rm -rf "$FIRST_RUN_SHOT_DIR"
step "first-run demo passed"
