#!/bin/bash
# Milestones demo and checks, end to end.
#
#   scripts/demo/milestones.sh             all checks + milestones UI tests, including the real-DSH demo
#   scripts/demo/milestones.sh --fake-only skip anything that needs DSH (CI-like)
#   scripts/demo/milestones.sh --shots     also refresh the screenshots in evidence/milestones/
#
# Real DSH: uses a bridge already listening on 127.0.0.1:$DSHM_BRIDGE_PORT, or starts
# `node scripts/demo/milestones-host.mjs` (DSH 0.2.2-rc.1 + DSH's mock LLM scripted to call todo_write,
# no API key) and stops it afterwards. That bridge must be the milestones host (the scripted three-todo model).
# Env (with defaults):
#   DSHM_BRIDGE_PORT 47812   DSHM_WEB_PORT 3285   DSHM_HOME ~/.dshm/home-milestones   DSHM_SIM dshm
#   DSHM_DD (DerivedData) /tmp/dshm-milestones-dd
# Node 24 from ~/.nvm and the pnpm shim from ~/.dshm/bin if present. Fails on any failed or
# skipped test; with --fake-only the real-DSH test is left out rather than skipped.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
FAKE_ONLY=0; SHOTS=0
for a in "$@"; do case "$a" in --fake-only) FAKE_ONLY=1 ;; --shots) SHOTS=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47812}"
export DSHM_WEB_PORT="${DSHM_WEB_PORT:-3285}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home-milestones}"
PORT="$DSHM_BRIDGE_PORT"
SIM="${DSHM_SIM:-dshm-milestones}"
NODE24="$HOME/.nvm/versions/node/v24.14.0/bin"
[ -d "$NODE24" ] && export PATH="$NODE24:$PATH"
[ -d "$HOME/.dshm/bin" ] && export PATH="$HOME/.dshm/bin:$PATH"
step() { printf '\n== %s\n' "$*"; }
source scripts/demo/lib.sh
demo_tls_home
LOGS="/tmp/dshm-s3-${DSHM_BRIDGE_PORT:-47801}"; mkdir -p "$LOGS"
DD="${DSHM_DD:-/tmp/dshm-milestones-dd}"

demo_prepare_bridge

step "bridge tests (node:test: milestone mapper against FakeDSH, golden fixtures)"
demo_bridge_tests "$LOGS/bridge-test.log"

step "DSHKit tests (swift test: MilestoneStoreTests against FakeBridge, golden fixtures)"
demo_swift_tests "$LOGS/swift-test.log"

DSH_PID=""
cleanup() { [ -n "$DSH_PID" ] && kill "$DSH_PID" 2>/dev/null || true; }
demo_tls_on_exit cleanup
if [ $FAKE_ONLY = 0 ]; then
  (cd bridge && corepack pnpm build >/dev/null)
  if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "The assigned bridge port is in use" >&2
    exit 1
  fi
  step "starting real DSH + bridge (scripts/demo/milestones-host.mjs, $DSHM_HOME, web $DSHM_WEB_PORT, bridge $PORT)"
  node scripts/demo/milestones-host.mjs > "$LOGS/host.log" 2>&1 &
  DSH_PID=$!
  for _ in $(seq 1 240); do lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.5; done
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null || { cat "$LOGS/host.log"; echo "bridge did not come up" >&2; exit 1; }
  step "bridge inside real DSH sends the milestone timeline to a CLI client"
  demo_tls_client "$DSHM_HOME" "$DSHM_HOME/cli.json" "Summarize this project in three steps." 2>&1 | tee "$LOGS/client.log"
  got=$(grep -oE "milestone [0-9]+ [A-Z_]+ \[[PIC]*\]" "$LOGS/client.log" | cut -d' ' -f3- | tr '\n' ' ')
  want="STARTED [] PLANNED [IPP] TODO_STARTED [IPP] TODO_DONE [CIP] TODO_STARTED [CIP] TODO_DONE [CCI] TODO_STARTED [CCI] TODO_DONE [CCC] FINISHED [CCC] "
  [ "$got" = "$want" ] || { echo "unexpected milestones: $got" >&2; exit 1; }
  echo "milestones as expected"
fi

step "milestones UI tests in the Simulator ($SIM)"
SHOT_DIR="$(mktemp -d)"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR" TEST_RUNNER_DSHM_BRIDGE_PORT="$PORT"
ONLY=(-only-testing:dsh-mobileUITests/MilestonesUITests)
if [ $FAKE_ONLY = 0 ]; then export TEST_RUNNER_DSHM_REAL_DSH=1
else ONLY+=(-skip-testing:dsh-mobileUITests/MilestonesUITests/testMilestonesAgainstRealDSH); fi
demo_tls_ui test -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates "${ONLY[@]}" \
  --log "$LOGS/uitest.log" || { grep -E "error:|Test Case" "$LOGS/uitest.log"; exit 1; }
grep -E "Test Case.*(passed|failed|skipped)" "$LOGS/uitest.log"
demo_no_skipped_ui "$LOGS/uitest.log"

if [ $SHOTS = 1 ]; then
  step "screenshots → ${DSHM_EVIDENCE:-evidence/milestones} (1/3 size)"
  mkdir -p ${DSHM_EVIDENCE:-evidence/milestones}
  for f in "$SHOT_DIR"/*.png; do
    out="${DSHM_EVIDENCE:-evidence/milestones}/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
step "milestones demo passed"
