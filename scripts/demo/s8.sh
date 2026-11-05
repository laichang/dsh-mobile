#!/bin/bash
# Run quick and structured replies with real DSH, then reopen the coding task offline.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0
for arg in "$@"; do case "$arg" in --shots) SHOTS=1 ;; *) echo "unknown arg $arg" >&2; exit 2 ;; esac; done
export PATH="$HOME/.dshm/bin:$HOME/.nvm/versions/node/v24.14.0/bin:$PATH"
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47814}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3287}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home-s8}"
SIM="${DSHM_SIM:-dshm-S8}"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
LOGS=/tmp/dshm-s8
mkdir -p "$LOGS"
source scripts/demo/lib.sh
demo_prepare_bridge
demo_bridge_tests "$LOGS/bridge.log"
demo_swift_tests "$LOGS/swift.log"
shot_dir="$(mktemp -d)"
host_pid=""
stop_host() {
  if [ -n "$host_pid" ]; then kill "$host_pid" 2>/dev/null || true; wait "$host_pid" || true; host_pid=""; fi
}
trap stop_host EXIT
start_host() {
  if lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null; then
    echo "S8 needs its own host on port $DSHM_BRIDGE_PORT" >&2; exit 1
  fi
  DSHM_MOCK_TEXT="$1" DSHM_MOCK_CHUNK_DELAY_MS="$2" node scripts/demo/s2-host.mjs > "$LOGS/host.log" 2>&1 &
  host_pid=$!
  for _ in $(seq 1 240); do
    lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null && return
    kill -0 "$host_pid" 2>/dev/null || { tail -10 "$LOGS/host.log"; exit 1; }
    sleep 0.5
  done
  echo "bridge did not start" >&2; exit 1
}
run_ui() {
  export TEST_RUNNER_DSHM_S8_REPLY="$1" TEST_RUNNER_DSHM_SHOT_DIR="$shot_dir" TEST_RUNNER_DSHM_BRIDGE_PORT="$DSHM_BRIDGE_PORT"
  local log="$LOGS/$1.log"
  xcodebuild test -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
    -derivedDataPath "${DSHM_DD:-/tmp/dshm-s8-dd}" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
    -parallel-testing-enabled NO -jobs 4 -only-testing:"dsh-mobileUITests/S8RichDetailUITests/$2" > "$log" 2>&1 || {
      grep -E 'error:|Test Case' "$log"; exit 1;
    }
  grep -E "Test Case.*$2.*passed" "$log"
  demo_no_skipped_ui "$log"
}
start_host 'Hello.' 20
run_ui translation testTranslationCompletesInline
stop_host
reply=$(cat <<'REPLY'
## Patch
Fixed the **return value**.

~~~diff
-return 0
+return 1
~~~

~~~console
$ swift test
1 test passed
~~~
REPLY
)
start_host "$reply" 330
run_ui coding testCodingReplyStreamsFences
stop_host
run_ui offline testCachedRichDetailAfterRelaunch
if [ "$SHOTS" = 1 ]; then
  mkdir -p evidence/S8
  for name in s8-inline-answer s8-rich-detail; do
    sips --resampleWidth 402 "$shot_dir/$name.png" --out "evidence/S8/$name.png" >/dev/null
  done
fi
echo "S8 demo passed"
