#!/bin/bash
# Real DSH reads one relative file from two git workspaces selected on the phone.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47815}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3288}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home-workspaces}" DSHM_BRIDGE_HOST=127.0.0.1 DSHM_BRIDGE_DEV_PLAINTEXT=1
SIM="${DSHM_SIM:-dshm-workspaces}"
DD="${DSHM_DD:-/tmp/dshm-workspaces-dd}"
export PATH="$HOME/.dshm/bin:$HOME/.nvm/versions/node/v24.14.0/bin:$PATH"
source scripts/demo/lib.sh
LOGS=/tmp/dshm-s7
mkdir -p "$LOGS"
demo_prepare_bridge
demo_bridge_tests "$LOGS/bridge.log"
demo_swift_tests "$LOGS/swift.log"

for port in "$DSHM_BRIDGE_PORT" "$DSHM_WEB_PORT"; do
  ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null || { echo "workspaces port $port is busy"; exit 1; }
done
fixtures="$DSHM_HOME/workspaces-demo-repos"
for repo in amber violet; do
  git init -q "$fixtures/$repo"
done
printf 'AMBER-MARKER\n' > "$fixtures/amber/project-label.txt"
printf 'VIOLET-MARKER\n' > "$fixtures/violet/project-label.txt"
# Isolated demo profile only: register the first repo as the bridge default.
mkdir -p "$DSHM_HOME/profiles/web"
printf '%s\n' '- id: dsh-mobile-bridge' '  config:' "    cwd: \"$fixtures/amber\"" > "$DSHM_HOME/profiles/web/cordis.patch.yml"
node scripts/demo/workspaces-host.mjs > "$LOGS/host.log" 2>&1 &
host_pid=$!
trap 'kill "$host_pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 240); do
  grep -q 'workspaces-host: ready' "$LOGS/host.log" && break
  kill -0 "$host_pid" 2>/dev/null || { tail -12 "$LOGS/host.log"; exit 1; }
  sleep 0.5
done
grep -q 'workspaces-host: ready' "$LOGS/host.log" || { tail -12 "$LOGS/host.log"; exit 1; }
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
export TEST_RUNNER_DSHM_BRIDGE_PORT="$DSHM_BRIDGE_PORT" TEST_RUNNER_DSHM_WORKSPACES_REPOS="$fixtures" TEST_RUNNER_DSHM_SHOT_DIR="$(mktemp -d)"
scripts/xc test -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  -jobs 4 -parallel-testing-enabled NO -only-testing:dsh-mobileUITests/WorkspaceUITests --log "$LOGS/ui.log" || {
    grep -E 'error:|Test Case|failed' "$LOGS/ui.log"; exit 1;
  }
grep -E "Test Case.*testSamePromptReadsTwoActualRepositories.*passed" "$LOGS/ui.log"
demo_no_skipped_ui "$LOGS/ui.log"
if [[ "${1:-}" == --shots ]]; then
  mkdir -p ${DSHM_EVIDENCE:-evidence/workspaces}
  for f in "$TEST_RUNNER_DSHM_SHOT_DIR"/*.png; do sips --resampleWidth 402 "$f" --out "${DSHM_EVIDENCE:-evidence/workspaces}/$(basename "$f")" >/dev/null; done
fi
echo "workspaces demo passed"
