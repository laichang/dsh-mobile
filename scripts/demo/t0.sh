#!/bin/bash
# T0 demo and checks, end to end (PLAN.md §3). Re-runnable evidence for T0's Done when items.
#
#   scripts/demo/t0.sh             all checks + UI tests, including the real-DSH demo
#   scripts/demo/t0.sh --fake-only skip anything that needs DSH (CI-like)
#   scripts/demo/t0.sh --shots     also refresh the screenshots in evidence/T0/
#
# Real DSH: uses a bridge already listening on 127.0.0.1:${DSHM_BRIDGE_PORT:-47801}, or starts
# `node scripts/dsh-up.mjs` (DSH 0.2.2-rc.1 + DSH's mock LLM, no API key) and stops it afterwards.
# Simulator: $DSHM_SIM (name or UDID, default "iPhone 17 Pro"). Node 24 from ~/.nvm if present.
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

step "codegen is up to date"
scripts/codegen --check

step "bridge tests (node:test, FakeDSH, golden fixtures)"
(cd bridge && corepack pnpm install --frozen-lockfile >/dev/null && corepack pnpm test)

step "DSHKit tests (swift test, FakeBridge, golden fixtures)"
swift test --package-path ios/DSHKit 2>&1 | grep -E "✔ Suite|✘|Test run"

DSH_PID=""
cleanup() { [ -n "$DSH_PID" ] && kill "$DSH_PID" 2>/dev/null || true; }
trap cleanup EXIT
if [ $FAKE_ONLY = 0 ]; then
  if ! lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    step "starting real DSH + bridge (scripts/dsh-up.mjs)"
    (cd bridge && corepack pnpm build >/dev/null)
    node scripts/dsh-up.mjs > /tmp/dshm-t0-dsh-up.log 2>&1 &
    DSH_PID=$!
    for _ in $(seq 1 240); do lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.5; done
    lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null || { cat /tmp/dshm-t0-dsh-up.log; echo "bridge did not come up" >&2; exit 1; }
  fi
  step "bridge inside real DSH answers a CLI client"
  node bridge/lib/scripts/client.js --port "$PORT" "用一句话介绍你自己。"
fi

step "UI tests in the Simulator ($SIM)"
SHOT_DIR="$(mktemp -d)"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR" TEST_RUNNER_DSHM_BRIDGE_PORT="$PORT"
[ $FAKE_ONLY = 0 ] && export TEST_RUNNER_DSHM_REAL_DSH=1
xcodebuild test -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath /tmp/dshm-t0-dd -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  > /tmp/dshm-t0-uitest.log 2>&1 || { grep -E "error:|Test Case" /tmp/dshm-t0-uitest.log; exit 1; }
grep -E "Test Case.*(passed|failed|skipped)" /tmp/dshm-t0-uitest.log

if [ $SHOTS = 1 ]; then
  step "screenshots → evidence/T0 (1/3 size)"
  mkdir -p evidence/T0
  for f in "$SHOT_DIR"/*.png; do
    out="evidence/T0/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
step "T0 demo passed"
