#!/bin/bash
# Demo and checks, end to end.
#
#   scripts/demo/durable-list.sh             all checks + UI tests, including kill/reopen against real DSH
#   scripts/demo/durable-list.sh --fake-only skip anything that needs DSH (CI-like)
#   scripts/demo/durable-list.sh --shots     also refresh the screenshots in evidence/durable-list/
#
# Env (with defaults):
#   DSHM_BRIDGE_PORT (47811)  DSHM_WEB_PORT (3284)  DSHM_HOME (~/.dshm/home-durable-list)
#   DSHM_SIM (Simulator name or UDID, default "dshm-durable-list")  DSHM_DD (DerivedData, /tmp/dshm-durable-list-dd)
# Fails on any failed or skipped test; with --fake-only the real-DSH tests are left out.
# Real DSH: starts `node scripts/demo/durable-list-host.mjs` (DSH 0.2.2-rc.1 + DSH's mock LLM, slowed to
# 250 ms per chunk, no API key), runs the kill/reopen demo, then stops the host and checks that
# the app names it as offline. If something already listens on the bridge port, it's used as is
# and the real-offline step is skipped (this script only stops a host it started).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
FAKE_ONLY=0; SHOTS=0
for a in "$@"; do case "$a" in --fake-only) FAKE_ONLY=1 ;; --shots) SHOTS=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47811}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3284}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home-durable-list}"
PORT="$DSHM_BRIDGE_PORT"
SIM="${DSHM_SIM:-dshm-durable-list}"
NODE24="$HOME/.nvm/versions/node/v24.14.0/bin"
[ -d "$NODE24" ] && export PATH="$NODE24:$PATH"
[ -d "$HOME/.dshm/bin" ] && export PATH="$HOME/.dshm/bin:$PATH"
LOGS=/tmp/dshm-s2-demo; mkdir -p "$LOGS"
step() { printf '\n== %s\n' "$*"; }
listening() { lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; }

source scripts/demo/lib.sh
demo_prepare_bridge

step "bridge tests (node:test, FakeDSH, golden fixtures; durable list: HostLog, ResumeAgainstFakeDSH)"
demo_bridge_tests "$LOGS/bridge-test.log"

step "DSHKit tests (swift test; durable list: TaskListStoreTests against FakeHost)"
demo_swift_tests "$LOGS/swift-test.log"

if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
DD="${DSHM_DD:-/tmp/dshm-durable-list-dd}"
SHOT_DIR="$(mktemp -d)"
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR" TEST_RUNNER_DSHM_BRIDGE_PORT="$PORT"

step "build the app and UI tests ($SIM)"
scripts/xc build-for-testing -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  --log "$LOGS/build.log" || { grep -E "error:" "$LOGS/build.log"; exit 1; }

uitest() { # name, then -only-testing targets
  local name=$1; shift
  scripts/xc test-without-building -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
    -derivedDataPath "$DD" "$@" --log "$LOGS/$name.log" \
    || { grep -E "error:|Test Case.*(passed|failed)" "$LOGS/$name.log"; exit 1; }
  grep -E "Test Case.*(passed|failed|skipped)" "$LOGS/$name.log"
  demo_no_skipped_ui "$LOGS/$name.log"
}

step "UI: offline host is named; cached milestones after kill/reopen (milestones seam) (FakeBridge, no DSH); the round-trip FakeBridge demo still passes"
uitest fake \
  -only-testing:dsh-mobileUITests/DurableListUITests/testOfflineHostIsNamedWithFakeBridge \
  -only-testing:dsh-mobileUITests/DurableListUITests/testCachedMilestonesAfterKillAndReopenWithFakeBridge \
  -only-testing:dsh-mobileUITests/RoundTripUITests/testDemoWithFakeBridge

HOST_PID=""
cleanup() { [ -n "$HOST_PID" ] && kill "$HOST_PID" 2>/dev/null || true; }
trap cleanup EXIT
if [ $FAKE_ONLY = 0 ]; then
  STARTED=0
  if ! listening; then
    step "starting real DSH + bridge (scripts/demo/durable-list-host.mjs: web $DSHM_WEB_PORT, bridge $PORT, $DSHM_HOME)"
    (cd bridge && corepack pnpm build >/dev/null)
    node scripts/demo/durable-list-host.mjs > "$LOGS/durable-list-host.log" 2>&1 &
    HOST_PID=$!
    STARTED=1
    for _ in $(seq 1 240); do listening && break; sleep 0.5; done
    listening || { cat "$LOGS/durable-list-host.log"; echo "bridge did not come up" >&2; exit 1; }
  fi
  step "bridge inside real DSH answers a CLI client"
  node bridge/lib/scripts/client.js --port "$PORT" "用一句话介绍你自己。"

  step "UI: start a task, kill the app, wait, reopen: list + transcript intact, gap filled (real DSH)"
  TEST_RUNNER_DSHM_REAL_DSH=1 uitest real \
    -only-testing:dsh-mobileUITests/DurableListUITests/testKillAndReopenAgainstRealDSH

  if [ $STARTED = 1 ]; then
    step "stop the host; UI: the list names it as offline (real bridge, now unreachable)"
    kill "$HOST_PID"; wait "$HOST_PID" 2>/dev/null || true; HOST_PID=""
    for _ in $(seq 1 40); do listening || break; sleep 0.25; done
    TEST_RUNNER_DSHM_EXPECT_OFFLINE=1 TEST_RUNNER_DSHM_HOST_NAME="$(node -p 'require("os").hostname()')" uitest offline \
      -only-testing:dsh-mobileUITests/DurableListUITests/testOfflineRealHostIsNamed
  else
    echo "the host on $PORT wasn't started by this script, so the real-offline step can't run; stop it and rerun" >&2
    exit 1
  fi
fi

if [ $SHOTS = 1 ]; then
  step "screenshots → ${DSHM_EVIDENCE:-evidence/durable-list} (1/3 size)"
  mkdir -p ${DSHM_EVIDENCE:-evidence/durable-list}
  for f in "$SHOT_DIR"/durable-list-*.png; do
    out="${DSHM_EVIDENCE:-evidence/durable-list}/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
step "durable-list demo passed"
