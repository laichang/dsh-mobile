#!/bin/bash
# Agent questions, end to end on real DSH and an iOS Simulator (screen P1).
# The mock model asks which of two templates to use (ask_user_question). The bridge holds the
# question; the app shows the card; a tap on an option answers; the task continues with that answer.
#
#   scripts/demo/questions.sh           bridge + DSHKit tests, then the UI test on real DSH
#   scripts/demo/questions.sh --shots   also refresh the screenshots in evidence/T1/
#
# Resources (scripts/slice-env): DSHM_BRIDGE_PORT, DSHM_WEB_PORT, DSHM_HOME, DSHM_SIM, DSHM_DD.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0
for a in "$@"; do case "$a" in --shots) SHOTS=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47800}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3283}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home}"
SIM="${DSHM_SIM:-iPhone 17 Pro}"
export PATH="$HOME/.dshm/bin:$HOME/.nvm/versions/node/v24.14.0/bin:$PATH"
source scripts/demo/lib.sh
LOGS=/tmp/dshm-questions-$DSHM_BRIDGE_PORT; mkdir -p "$LOGS"
SHOTDIR=$(mktemp -d)
mkdir -p "$DSHM_HOME"
# A disposable DSH profile, so the scripted mock model never touches the normal one.
PROFILE=$(mktemp -d "$DSHM_HOME/questions-demo.XXXXXX")
PID=""
cleanup() { if [ -n "$PID" ]; then kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; fi; rm -rf "$PROFILE" "$SHOTDIR"; }
trap cleanup EXIT

demo_prepare_bridge
demo_bridge_tests "$LOGS/bridge-test.log"
demo_swift_tests "$LOGS/swift-test.log"
(cd bridge && corepack pnpm build >/dev/null)

printf '\n== %s\n' "real DSH + bridge, mock model asks a question"
if lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port $DSHM_BRIDGE_PORT is in use; stop that bridge first" >&2; exit 1
fi
DSHM_HOME="$PROFILE" node scripts/demo/questions-host.mjs > "$LOGS/host.log" 2>&1 &
PID=$!
for _ in $(seq 1 180); do
  grep -q 'questions-host: ready' "$LOGS/host.log" && break
  kill -0 "$PID" 2>/dev/null || { tail -20 "$LOGS/host.log"; exit 1; }
  sleep 0.5
done
grep -q 'questions-host: ready' "$LOGS/host.log" || { echo "questions host did not become ready"; tail -20 "$LOGS/host.log"; exit 1; }

printf '\n== %s\n' "UI test in the Simulator ($SIM)"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
export TEST_RUNNER_DSHM_QUESTIONS_HOST=1 TEST_RUNNER_DSHM_BRIDGE_PORT="$DSHM_BRIDGE_PORT" TEST_RUNNER_DSHM_SHOT_DIR="$SHOTDIR"
xcodebuild test -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "${DSHM_DD:-/tmp/dshm-questions-dd}" -parallel-testing-enabled NO -jobs 4 \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -only-testing:dsh-mobileUITests/AgentQuestionUITests \
  > "$LOGS/uitest.log" 2>&1 || { grep -E 'error:|Test Case|XCTAssert' "$LOGS/uitest.log" | tail -24; exit 1; }
grep -E 'Test Case.*(passed|failed|skipped)' "$LOGS/uitest.log"
demo_no_skipped_ui "$LOGS/uitest.log"
if [ $SHOTS = 1 ]; then
  mkdir -p evidence/T1
  for f in "$SHOTDIR"/*.png; do sips --resampleWidth 402 "$f" --out "evidence/T1/$(basename "$f")" >/dev/null; done
fi
echo 'questions demo passed'
