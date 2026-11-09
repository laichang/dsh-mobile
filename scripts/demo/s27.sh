#!/bin/bash
# S27 demo and checks: Outcome duration and marker (PLAN.md §5 S27, ARCHITECTURE D76). The done
# footer's 用时 counts the latest turn only (the bridge's `turn_started_at_ms`), and an unread done
# session opens at the start of its final answer with no label there. The UI tests run against the
# in-process FakeBridge (scenarios `turns` and `outcomes`); no DSH is needed.
#
#   scripts/demo/s27.sh          bridge tests (pnpm test), DSHKit LastTurnTests,
#                                S27OutcomeFooterUITests, then the seams:
#                                S19OutcomesUITests (done and failed) and S23DrawerMotionUITests
#                                (landing positions)
#   DSHM_RESUME=1               skip the parts that passed for the same code (lib.sh demo_part)
#
# Resources (WORKFLOW.md §6), read from the environment:
#   DSHM_SIM dshm-S27   DSHM_DD (DerivedData) /tmp/dshm-s27-dd
#   (DSHM_BRIDGE_PORT 47810, DSHM_WEB_PORT 3283, DSHM_HOME ~/.dshm/home-s27 are S27's, unused here.)
# Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
for a in "$@"; do echo "unknown arg $a" >&2; exit 2; done
export DSHM_SIM="${DSHM_SIM:-dshm-S27}" DSHM_DD="${DSHM_DD:-/tmp/dshm-s27-dd}"
step() { printf '\n== %s\n' "$*"; }
source scripts/demo/lib.sh
LOGS=/tmp/dshm-s27; mkdir -p "$LOGS"
SIM="$DSHM_SIM"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi

step "bridge: pnpm test (log: $LOGS/bridge.log)"
if ! demo_part bridge bash -c '(cd bridge && pnpm install --frozen-lockfile >/dev/null) && scripts/pnpm-test --log "$1"' \
  _ "$LOGS/bridge.log"; then
  echo "bridge tests failed" >&2; exit 1
fi

step "DSHKit: LastTurnTests (log: $LOGS/dshkit.log)"
if ! demo_part dshkit scripts/swift-test --package-path ios/DSHKit --filter LastTurnTests --log "$LOGS/dshkit.log"; then
  echo "DSHKit tests failed" >&2; exit 1
fi

step "build the app and UI tests ($SIM)"
scripts/xc build-for-testing -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DSHM_DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  --log "$LOGS/build.log" || { grep -E "error:" "$LOGS/build.log"; exit 1; }

# One part per UI test class (lib.sh demo_part): a failure in one does not run the others again.
ui_part() { # name, then -only-testing selectors
  local name=$1; shift
  local args=() t
  for t in "$@"; do args+=("-only-testing:dsh-mobileUITests/$t"); done
  step "UI: $name (log: $LOGS/ui-$name.log)"
  if demo_part "ui-$name" scripts/xc test-without-building -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile \
      -destination "$DEST" -derivedDataPath "$DSHM_DD" -parallel-testing-enabled NO "${args[@]}" \
      --log "$LOGS/ui-$name.log"; then
    grep -E "Test Case.*(passed|failed|skipped)" "$LOGS/ui-$name.log" || true
  else
    grep -E "error:|Test Case.*(passed|failed)" "$LOGS/ui-$name.log" || tail -30 "$LOGS/ui-$name.log"
    echo "UI tests failed: $name" >&2
    exit 1
  fi
  demo_no_skipped_ui "$LOGS/ui-$name.log"
}

ui_part s27 S27OutcomeFooterUITests
# The seams: S19's done and failed pages, and S23's landing positions (both land at the answer's start).
ui_part s19-seam S19OutcomesUITests
ui_part s23-seam S23DrawerMotionUITests

step "S27 demo passed"
