#!/bin/bash
# S2 demo and checks, end to end (PLAN.md §5 S2). Re-runnable evidence for S2's Done when items.
#
#   scripts/demo/s2.sh             all checks + UI tests, including kill/reopen against real DSH
#   scripts/demo/s2.sh --fake-only skip anything that needs DSH (CI-like)
#   scripts/demo/s2.sh --shots     also refresh the screenshots in evidence/S2/
#
# Env (defaults are S2's resources, PLAN.md §8 2026-11-05):
#   DSHM_BRIDGE_PORT (47811)  DSHM_WEB_PORT (3284)  DSHM_HOME (~/.dshm/home-s2)
#   DSHM_SIM (Simulator name or UDID, default "dshm-S2")
# Real DSH: starts `node scripts/demo/s2-host.mjs` (DSH 0.2.2-rc.1 + DSH's mock LLM, slowed to
# 250 ms per chunk, no API key), runs the kill/reopen demo, then stops the host and checks that
# the app names it as offline. If something already listens on the bridge port, it's used as is
# and the real-offline step is skipped (this script only stops a host it started).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
FAKE_ONLY=0; SHOTS=0
for a in "$@"; do case "$a" in --fake-only) FAKE_ONLY=1 ;; --shots) SHOTS=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47811}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3284}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home-s2}"
PORT="$DSHM_BRIDGE_PORT"
SIM="${DSHM_SIM:-dshm-S2}"
NODE24="$HOME/.nvm/versions/node/v24.14.0/bin"
[ -d "$NODE24" ] && export PATH="$NODE24:$PATH"
[ -d "$HOME/.dshm/bin" ] && export PATH="$HOME/.dshm/bin:$PATH"
LOGS=/tmp/dshm-s2-demo; mkdir -p "$LOGS"
step() { printf '\n== %s\n' "$*"; }
listening() { lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; }

step "codegen is up to date"
scripts/codegen --check

step "bridge tests (node:test, FakeDSH, golden fixtures; S2: HostLog, ResumeAgainstFakeDSH)"
(cd bridge && corepack pnpm install --frozen-lockfile >/dev/null && corepack pnpm test 2>&1 | grep -E "^[▶✔✖]|^  [✔✖]|^ℹ (pass|fail)")

step "DSHKit tests (swift test; S2: TaskListStoreTests against FakeHost)"
swift test --package-path ios/DSHKit 2>&1 | grep -E "✔ Suite|✘|Test run"

if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
DD=/tmp/dshm-s2-dd
SHOT_DIR="$(mktemp -d)"
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR" TEST_RUNNER_DSHM_BRIDGE_PORT="$PORT"

step "build the app and UI tests ($SIM)"
xcodebuild build-for-testing -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  > "$LOGS/build.log" 2>&1 || { grep -E "error:" "$LOGS/build.log"; exit 1; }

uitest() { # name, then -only-testing targets
  local name=$1; shift
  xcodebuild test-without-building -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
    -derivedDataPath "$DD" "$@" > "$LOGS/$name.log" 2>&1 \
    || { grep -E "error:|Test Case.*(passed|failed)" "$LOGS/$name.log"; exit 1; }
  grep -E "Test Case.*(passed|failed|skipped)" "$LOGS/$name.log"
}

step "UI: offline host is named (FakeBridge, no DSH); T0's FakeBridge demo still passes"
uitest fake \
  -only-testing:dsh-mobileUITests/S2DurableListUITests/testOfflineHostIsNamedWithFakeBridge \
  -only-testing:dsh-mobileUITests/T0DemoUITests/testDemoWithFakeBridge

HOST_PID=""
cleanup() { [ -n "$HOST_PID" ] && kill "$HOST_PID" 2>/dev/null || true; }
trap cleanup EXIT
if [ $FAKE_ONLY = 0 ]; then
  STARTED=0
  if ! listening; then
    step "starting real DSH + bridge (scripts/demo/s2-host.mjs: web $DSHM_WEB_PORT, bridge $PORT, $DSHM_HOME)"
    (cd bridge && corepack pnpm build >/dev/null)
    node scripts/demo/s2-host.mjs > "$LOGS/s2-host.log" 2>&1 &
    HOST_PID=$!
    STARTED=1
    for _ in $(seq 1 240); do listening && break; sleep 0.5; done
    listening || { cat "$LOGS/s2-host.log"; echo "bridge did not come up" >&2; exit 1; }
  fi
  step "bridge inside real DSH answers a CLI client"
  node bridge/lib/scripts/client.js --port "$PORT" "用一句话介绍你自己。"

  step "UI: start a task, kill the app, wait, reopen: list + transcript intact, gap filled (real DSH)"
  TEST_RUNNER_DSHM_REAL_DSH=1 uitest real \
    -only-testing:dsh-mobileUITests/S2DurableListUITests/testKillAndReopenAgainstRealDSH

  if [ $STARTED = 1 ]; then
    step "stop the host; UI: the list names it as offline (real bridge, now unreachable)"
    kill "$HOST_PID"; wait "$HOST_PID" 2>/dev/null || true; HOST_PID=""
    for _ in $(seq 1 40); do listening || break; sleep 0.25; done
    TEST_RUNNER_DSHM_EXPECT_OFFLINE=1 TEST_RUNNER_DSHM_HOST_NAME="$(node -p 'require("os").hostname()')" uitest offline \
      -only-testing:dsh-mobileUITests/S2DurableListUITests/testOfflineRealHostIsNamed
  else
    step "skipped the real-offline step: the host on $PORT wasn't started by this script"
  fi
fi

if [ $SHOTS = 1 ]; then
  step "screenshots → evidence/S2 (1/3 size)"
  mkdir -p evidence/S2
  for f in "$SHOT_DIR"/s2-*.png; do
    out="evidence/S2/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
step "S2 demo passed"
