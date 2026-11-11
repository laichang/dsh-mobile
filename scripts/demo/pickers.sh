#!/bin/bash
# Demo and checks: the workspace sheet (07) and the model sheet (M, X4).
# FakeBridge: two in-process hosts with models
# and workspaces (`-DSHMFakeBridge pickers`); no DSH and no port is needed for the pickers tests.
#
#   scripts/demo/pickers.sh            swift test, PickersUITests, and the FakeBridge UI tests of
#                                  earlier slices that use the "host · workspace" line
#   scripts/demo/pickers.sh --shots    also refresh the screenshots in evidence/pickers/ (1/3 size)
#   scripts/demo/pickers.sh --regress  also run models.sh and workspaces.sh (real DSH: the model and workspace
#                                  sheets against the real bridge), with the pickers resources
#
# Resources, read from the environment (scripts/slice-env):
#   DSHM_SIM dshm-pickers   DSHM_DD (DerivedData) /tmp/dshm-pickers-dd
#   --regress only: DSHM_BRIDGE_PORT 47815, DSHM_WEB_PORT 3288, DSHM_HOME ~/.dshm/home-pickers
# Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0; REGRESS=0
for a in "$@"; do case "$a" in --shots) SHOTS=1 ;; --regress) REGRESS=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
export DSHM_SIM="${DSHM_SIM:-dshm-pickers}" DSHM_DD="${DSHM_DD:-/tmp/dshm-pickers-dd}"
NODE24="$HOME/.nvm/versions/node/v24.14.0/bin"
[ -d "$NODE24" ] && export PATH="$NODE24:$PATH"
step() { printf '\n== %s\n' "$*"; }
SIM="$DSHM_SIM"
source scripts/demo/lib.sh
LOGS=/tmp/dshm-s20; mkdir -p "$LOGS"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
export DEST

step "DSHKit tests (swift test, FakeBridge, FakePickers)"
# demo_part (lib.sh): with DSHM_RESUME=1 or on a retry in scripts/review, a part that passed for
# the same code does not run again.
demo_part pickers-swift-test bash -c 'source scripts/demo/lib.sh; demo_swift_tests "$1"' _ "$LOGS/swift-test.log"

SHOT_DIR="$(mktemp -d)"
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR"

step "UI: the workspace and model sheets, and the shell and multi-host FakeBridge tests of the composer line"
UI_TESTS=(
  -only-testing:dsh-mobileUITests/PickersUITests
  -only-testing:dsh-mobileUITests/ShellUITests/testLaunchShowsBlankNewSession
  -only-testing:dsh-mobileUITests/MultiHostUITests
)
demo_part pickers-ui bash -c '
  log=$1; shift
  scripts/xc build-for-testing -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
    -derivedDataPath "$DSHM_DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
    --log "${log%.log}-build.log" || { grep -E "error:" "${log%.log}-build.log"; exit 1; }
  scripts/xc test-without-building -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
    -derivedDataPath "$DSHM_DD" -parallel-testing-enabled NO "$@" --log "$log" \
    || { grep -E "error:|Test Case.*(passed|failed)" "$log"; exit 1; }
  grep -E "Test Case.*(passed|failed|skipped)" "$log"
  source scripts/demo/lib.sh; demo_no_skipped_ui "$log"' _ "$LOGS/ui.log" "${UI_TESTS[@]}"

if [ $REGRESS = 1 ]; then
  export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47815}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3288}"
  export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home-pickers}"
  step "regression: model sheet with real DSH (scripts/demo/models.sh)"
  demo_part pickers-regress-s6 scripts/demo/models.sh
  step "regression: workspace sheet with real DSH (scripts/demo/workspaces.sh)"
  demo_part pickers-regress-s7 scripts/demo/workspaces.sh
fi

if [ $SHOTS = 1 ]; then
  step "screenshots → ${DSHM_EVIDENCE:-evidence/pickers} (1/3 size)"
  mkdir -p ${DSHM_EVIDENCE:-evidence/pickers}
  for f in "$SHOT_DIR"/pickers-*.png; do
    [ -e "$f" ] || { echo "no new shots (the UI part was skipped)"; break; }
    out="${DSHM_EVIDENCE:-evidence/pickers}/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
step "pickers demo passed"
