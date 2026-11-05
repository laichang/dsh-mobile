#!/bin/bash
# S3 · Milestones demo and checks, end to end (PLAN.md §5 S3). Re-runnable evidence for S3's
# Done when items.
#
#   scripts/demo/s3.sh             all checks + S3 UI tests, including the real-DSH demo
#   scripts/demo/s3.sh --fake-only skip anything that needs DSH (CI-like)
#   scripts/demo/s3.sh --shots     also refresh the screenshots in evidence/S3/
#
# Real DSH: uses a bridge already listening on 127.0.0.1:$DSHM_BRIDGE_PORT, or starts
# `node scripts/demo/s3-host.mjs` (DSH 0.2.2-rc.1 + DSH's mock LLM scripted to call todo_write,
# no API key) and stops it afterwards. That bridge must be S3's (the scripted three-todo model).
# Env (defaults are S3's resources, PLAN.md §8):
#   DSHM_BRIDGE_PORT 47812   DSHM_WEB_PORT 3285   DSHM_HOME ~/.dshm/home-s3   DSHM_SIM dshm-S3
# Node 24 from ~/.nvm and the pnpm shim from ~/.dshm/bin if present.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
FAKE_ONLY=0; SHOTS=0
for a in "$@"; do case "$a" in --fake-only) FAKE_ONLY=1 ;; --shots) SHOTS=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47812}"
export DSHM_WEB_PORT="${DSHM_WEB_PORT:-3285}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home-s3}"
PORT="$DSHM_BRIDGE_PORT"
SIM="${DSHM_SIM:-dshm-S3}"
NODE24="$HOME/.nvm/versions/node/v24.14.0/bin"
[ -d "$NODE24" ] && export PATH="$NODE24:$PATH"
[ -d "$HOME/.dshm/bin" ] && export PATH="$HOME/.dshm/bin:$PATH"
step() { printf '\n== %s\n' "$*"; }

step "codegen is up to date"
scripts/codegen --check

step "bridge tests (node:test: milestone mapper against FakeDSH, golden fixtures)"
(cd bridge && corepack pnpm install --frozen-lockfile >/dev/null && corepack pnpm test 2>&1 | grep -E "^[▶✔✖]|^  [✔✖]|^ℹ (pass|fail)")

step "DSHKit tests (swift test: MilestoneStoreTests against FakeBridge, golden fixtures)"
swift test --package-path ios/DSHKit 2>&1 | grep -E "✔ Suite|✘|Test run"

DSH_PID=""
cleanup() { [ -n "$DSH_PID" ] && kill "$DSH_PID" 2>/dev/null || true; }
trap cleanup EXIT
if [ $FAKE_ONLY = 0 ]; then
  (cd bridge && corepack pnpm build >/dev/null)
  if ! lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    step "starting real DSH + bridge (scripts/demo/s3-host.mjs, $DSHM_HOME, web $DSHM_WEB_PORT, bridge $PORT)"
    node scripts/demo/s3-host.mjs > /tmp/dshm-s3-host.log 2>&1 &
    DSH_PID=$!
    for _ in $(seq 1 240); do lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.5; done
    lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null || { cat /tmp/dshm-s3-host.log; echo "bridge did not come up" >&2; exit 1; }
  fi
  step "bridge inside real DSH sends the milestone timeline to a CLI client"
  node bridge/lib/scripts/client.js --port "$PORT" "Summarize this project in three steps." 2>&1 | tee /tmp/dshm-s3-client.log
  got=$(grep -oE "milestone [0-9]+ [A-Z_]+ \[[PIC]*\]" /tmp/dshm-s3-client.log | cut -d' ' -f3- | tr '\n' ' ')
  want="STARTED [] PLANNED [IPP] TODO_STARTED [IPP] TODO_DONE [CIP] TODO_STARTED [CIP] TODO_DONE [CCI] TODO_STARTED [CCI] TODO_DONE [CCC] FINISHED [CCC] "
  [ "$got" = "$want" ] || { echo "unexpected milestones: $got" >&2; exit 1; }
  echo "milestones as expected"
fi

step "S3 UI tests in the Simulator ($SIM)"
SHOT_DIR="$(mktemp -d)"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR" TEST_RUNNER_DSHM_BRIDGE_PORT="$PORT"
[ $FAKE_ONLY = 0 ] && export TEST_RUNNER_DSHM_REAL_DSH=1
xcodebuild test -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath /tmp/dshm-s3-dd -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  -only-testing:dsh-mobileUITests/S3MilestonesUITests \
  > /tmp/dshm-s3-uitest.log 2>&1 || { grep -E "error:|Test Case" /tmp/dshm-s3-uitest.log; exit 1; }
grep -E "Test Case.*(passed|failed|skipped)" /tmp/dshm-s3-uitest.log
if [ $FAKE_ONLY = 0 ] && grep -q "testMilestonesAgainstRealDSH.*skipped" /tmp/dshm-s3-uitest.log; then
  echo "real-DSH UI test was skipped" >&2; exit 1
fi

if [ $SHOTS = 1 ]; then
  step "screenshots → evidence/S3 (1/3 size)"
  mkdir -p evidence/S3
  for f in "$SHOT_DIR"/*.png; do
    out="evidence/S3/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
step "S3 demo passed"
