#!/bin/bash
# S9: send tasks to two independent FakeBridge hosts, then reopen with one host offline.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0
for arg in "$@"; do case "$arg" in --shots) SHOTS=1 ;; *) echo "unknown arg $arg" >&2; exit 2 ;; esac; done
export PATH="$HOME/.dshm/bin:$HOME/.nvm/versions/node/v24.14.0/bin:$PATH"
SIM="${DSHM_SIM:-dshm-S9}"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
LOGS=/tmp/dshm-s9; mkdir -p "$LOGS"
source scripts/demo/lib.sh
demo_prepare_bridge
demo_bridge_tests "$LOGS/bridge.log"
demo_swift_tests "$LOGS/swift.log"
export TEST_RUNNER_DSHM_SHOT_DIR="$(mktemp -d)"
xcodebuild test -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "${DSHM_DD:-/tmp/dshm-s9-dd}" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  -parallel-testing-enabled NO -jobs 4 -only-testing:dsh-mobileUITests/S9MultiHostUITests > "$LOGS/ui.log" 2>&1 || {
    grep -E 'error:|Test Case|XCTAssert' "$LOGS/ui.log"; exit 1;
  }
grep -E 'Test Case.*testTwoHostsShareTheListAndTheOfflineHostIsNamed.*passed' "$LOGS/ui.log"
demo_no_skipped_ui "$LOGS/ui.log"
if [[ "$SHOTS" == 1 ]]; then
  mkdir -p evidence/S9
  for name in s9-two-hosts s9-office-offline; do
    sips --resampleWidth 402 "$TEST_RUNNER_DSHM_SHOT_DIR/$name.png" --out "evidence/S9/$name.png" >/dev/null
  done
fi
echo 'S9 demo passed'
