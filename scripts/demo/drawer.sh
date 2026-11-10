#!/bin/bash
# Demo and checks: the workspace drawer. Re-runnable evidence for its checks.
#
#   scripts/demo/drawer.sh            bridge tests, swift test, the FakeBridge drawer UI tests, and the
#                                  real-DSH demo (a Web session and a phone session in one workspace)
#   scripts/demo/drawer.sh --shots    also refresh the screenshots in evidence/drawer/ (1/3 size)
#   DSHM_RESUME=1                  skip the parts that passed for the same code (lib.sh demo_part)
#
# Resources (WORKFLOW.md §6), read from the environment:
#   DSHM_BRIDGE_PORT 47811   DSHM_WEB_PORT 3284   DSHM_HOME ~/.dshm/home-drawer   DSHM_SIM dshm
#   DSHM_DD (DerivedData) /tmp/dshm-drawer-dd
# The FakeBridge part needs nothing else. The real part runs scripts/demo/drawer-web.mjs: DSH Web with
# the bridge plugin and DSH's mock LLM, in a fresh DSH home under DSHM_HOME. Fails on any failed or
# skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0; PART=""
while [ $# -gt 0 ]; do
  case "$1" in
    --shots) SHOTS=1 ;;
    --part) PART="$2"; shift ;;
    *) echo "usage: $0 [--shots]" >&2; exit 2 ;;
  esac
  shift
done
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47811}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3284}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home-drawer}" DSHM_SIM="${DSHM_SIM:-dshm-drawer}"
export DSHM_DD="${DSHM_DD:-/tmp/dshm-drawer-dd}"
export DSHM_BRIDGE_HOST=127.0.0.1 DSHM_BRIDGE_DEV_PLAINTEXT=1
export PATH="$HOME/.dshm/bin:$HOME/.nvm/versions/node/v24.14.0/bin:$PATH"
step() { printf '\n== %s\n' "$*"; }
source scripts/demo/lib.sh
LOGS="/tmp/dshm-s14-${DSHM_SIM}"; mkdir -p "$LOGS" "$DSHM_HOME"
export DSHM_DRAWER_SHOTS="${DSHM_DRAWER_SHOTS:-$LOGS/shots}"; mkdir -p "$DSHM_DRAWER_SHOTS"
SIM="$DSHM_SIM"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
export TEST_RUNNER_DSHM_SHOT_DIR="$DSHM_DRAWER_SHOTS"
UI=(scripts/xc test-without-building -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST"
  -derivedDataPath "$DSHM_DD" -parallel-testing-enabled NO)
REAL=dsh-mobileUITests/DrawerUITests/testWebAndPhoneSessionsShareAWorkspaceWithRealDSH

ui_check() { # log: every test passed, none skipped
  grep -E "Test Case.*(passed|failed|skipped)" "$1"
  demo_no_skipped_ui "$1"
}

case "$PART" in
  ui-fake)
    step "UI: drawer tree, marks, badge, offline host, no drawer.v1 (FakeBridge)"
    "${UI[@]}" -only-testing:dsh-mobileUITests/DrawerUITests -skip-testing:"$REAL" --log "$LOGS/ui-fake.log" \
      || { grep -E "error:|Test Case.*(passed|failed)" "$LOGS/ui-fake.log"; exit 1; }
    ui_check "$LOGS/ui-fake.log"
    exit 0 ;;
  ui-real)
    step "UI: a Web session and a phone session in one workspace (real DSH Web + bridge)"
    for port in "$DSHM_BRIDGE_PORT" "$DSHM_WEB_PORT"; do
      ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null || { echo "drawer port $port is busy" >&2; exit 1; }
    done
    (cd bridge && corepack pnpm build >/dev/null)
    # DSH initializes its default workspace only on first use: a fresh DSH home for each run.
    export DSHM_HOME="$(mktemp -d "$DSHM_HOME/run.XXXXXX")"
    export DSHM_DRAWER_SIGNALS="$(mktemp -d)"
    export TEST_RUNNER_DSHM_DRAWER_SIGNALS="$DSHM_DRAWER_SIGNALS"
    node scripts/demo/drawer-web.mjs > "$LOGS/web.log" 2>&1 &
    web_pid=$!
    cleanup() { kill "$web_pid" 2>/dev/null || true; wait "$web_pid" 2>/dev/null || true; rm -rf "$DSHM_HOME" "$DSHM_DRAWER_SIGNALS"; }
    trap cleanup EXIT
    for _ in $(seq 1 240); do
      [ -e "$DSHM_DRAWER_SIGNALS/workspace" ] && break
      kill -0 "$web_pid" 2>/dev/null || { cat "$LOGS/web.log"; exit 1; }
      sleep 0.5
    done
    [ -e "$DSHM_DRAWER_SIGNALS/workspace" ] || { cat "$LOGS/web.log"; exit 1; }
    "${UI[@]}" -only-testing:"$REAL" --log "$LOGS/ui-real.log" \
      || { grep -E "error:|Test Case.*(passed|failed)" "$LOGS/ui-real.log"; cat "$LOGS/web.log"; exit 1; }
    ui_check "$LOGS/ui-real.log"
    wait "$web_pid" || { cat "$LOGS/web.log"; exit 1; }
    cat "$LOGS/web.log"
    exit 0 ;;
  "") ;;
  *) echo "unknown part $PART" >&2; exit 2 ;;
esac

demo_prepare_bridge
step "bridge tests (node:test, FakeDSH, golden fixtures; DrawerWorkspaces)"
demo_bridge_tests "$LOGS/bridge-test.log"
step "DSHKit tests (swift test; DrawerTreeTests)"
demo_swift_tests "$LOGS/swift-test.log"

step "build the app and UI tests ($SIM)"
scripts/xc build-for-testing -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DSHM_DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  --log "$LOGS/build.log" || { grep -E "error:" "$LOGS/build.log"; exit 1; }

rm -f "$DSHM_DRAWER_SHOTS"/*.png
demo_part drawer-ui-fake "$0" --part ui-fake
demo_part drawer-ui-real "$0" --part ui-real

if [ $SHOTS = 1 ]; then
  step "screenshots → ${DSHM_EVIDENCE:-evidence/drawer} (1/3 size)"
  mkdir -p ${DSHM_EVIDENCE:-evidence/drawer}
  for f in "$DSHM_DRAWER_SHOTS"/drawer-*.png; do
    out="${DSHM_EVIDENCE:-evidence/drawer}/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
step "drawer demo passed"
