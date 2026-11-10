#!/bin/bash
# Rich detail against a real DSH with a mock model (#22): RichDetailUITests.
# A short reply shows inline in 所有任务; a coding reply streams its fences (diff, console); then,
# with the host stopped, the app opens again and shows the coding task from its cache, offline.
#
#   scripts/demo/rich-detail.sh                 bridge + DSHKit tests, then the three UI tests in order
#   scripts/demo/rich-detail.sh --offline-only  only testCachedRichDetailAfterRelaunch, on the cache
#                                               an earlier full run left in the simulator
#   scripts/demo/rich-detail.sh --shots         also refresh the screenshots in evidence/rich-detail/ (1/3 size)
#
# Resources, read from the environment (eval "$(scripts/slice-env <ID>)"); the
# defaults: DSHM_BRIDGE_PORT 47811, DSHM_WEB_PORT 3284, DSHM_HOME ~/.dshm/home-rich-detail,
# DSHM_SIM dshm-rich-detail, DSHM_DD (DerivedData) /tmp/dshm-rich-detail-dd. Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0 OFFLINE_ONLY=0
for arg in "$@"; do case "$arg" in --shots) SHOTS=1 ;; --offline-only) OFFLINE_ONLY=1 ;; *) echo "unknown arg $arg" >&2; exit 2 ;; esac; done
export PATH="$HOME/.dshm/bin:$HOME/.nvm/versions/node/v24.14.0/bin:$PATH"
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47811}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3284}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home-rich-detail}"
export DSHM_SIM="${DSHM_SIM:-dshm-rich-detail}"
DD="${DSHM_DD:-/tmp/dshm-rich-detail-dd}"
SIM="$DSHM_SIM"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
LOGS="/tmp/dshm-rich-detail-$SIM"
mkdir -p "$LOGS"
step() { printf '\n== %s\n' "$*"; }
source scripts/demo/lib.sh
if [ "$OFFLINE_ONLY" = 0 ]; then
  demo_prepare_bridge
  step "bridge tests"
  demo_bridge_tests "$LOGS/bridge.log"
  step "DSHKit tests"
  demo_swift_tests "$LOGS/swift.log"
fi

step "build the app and UI tests ($SIM, log: $LOGS/build.log)"
scripts/xc build-for-testing -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  --log "$LOGS/build.log" || { grep -E "error:" "$LOGS/build.log"; exit 1; }

shot_dir="$(mktemp -d)"
host_pid=""
stop_host() {
  if [ -n "$host_pid" ]; then kill "$host_pid" 2>/dev/null || true; wait "$host_pid" || true; host_pid=""; fi
}
trap stop_host EXIT
start_host() { # mock reply, ms per chunk
  if lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null; then
    echo "rich-detail needs its own host on port $DSHM_BRIDGE_PORT" >&2; exit 1
  fi
  DSHM_MOCK_TEXT="$1" DSHM_MOCK_CHUNK_DELAY_MS="$2" node scripts/demo/durable-list-host.mjs > "$LOGS/host.log" 2>&1 &
  host_pid=$!
  for _ in $(seq 1 240); do
    lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null && return
    kill -0 "$host_pid" 2>/dev/null || { tail -10 "$LOGS/host.log"; exit 1; }
    sleep 0.5
  done
  echo "bridge did not start" >&2; exit 1
}
run_ui() { # DSHM_RICH_REPLY, test name
  export TEST_RUNNER_DSHM_RICH_REPLY="$1" TEST_RUNNER_DSHM_SHOT_DIR="$shot_dir" TEST_RUNNER_DSHM_BRIDGE_PORT="$DSHM_BRIDGE_PORT"
  local log="$LOGS/$1.log"
  step "UI: RichDetailUITests/$2 (log: $log)"
  scripts/xc test-without-building -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
    -derivedDataPath "$DD" -parallel-testing-enabled NO \
    -only-testing:"dsh-mobileUITests/RichDetailUITests/$2" --log "$log" || {
      grep -E 'error:|Test Case' "$log"; echo "UI test failed: $2" >&2; exit 1;
    }
  grep -E "Test Case.*$2.*passed" "$log"
  # The test's own guard against an app that liveactivitiesd opened without the launch arguments.
  grep -m1 -E "^rich-detail: .*launching it again" "$log" || true
  demo_no_skipped_ui "$log"
}

if [ "$OFFLINE_ONLY" = 1 ]; then
  run_ui offline testCachedRichDetailAfterRelaunch
  step "rich-detail offline part passed"
  exit 0
fi
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
# The host is down: the app opens offline, from its cache.
run_ui offline testCachedRichDetailAfterRelaunch
if [ "$SHOTS" = 1 ]; then
  step "screenshots → ${DSHM_EVIDENCE:-evidence/rich-detail} (1/3 size)"
  mkdir -p ${DSHM_EVIDENCE:-evidence/rich-detail}
  for name in rich-detail-inline-answer rich-detail-rich-detail; do
    sips --resampleWidth 402 "$shot_dir/$name.png" --out "${DSHM_EVIDENCE:-evidence/rich-detail}/$name.png" >/dev/null
  done
fi
step "rich-detail demo passed"
