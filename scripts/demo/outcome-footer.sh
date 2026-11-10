#!/bin/bash
# Demo and checks: Outcome duration and marker. The done
# footer's 用时 counts the latest turn only (the bridge's `turn_started_at_ms`), and an unread done
# session opens at the start of its final answer with no label there. The UI tests run against the
# in-process FakeBridge (scenarios `turns` and `outcomes`); no DSH is needed.
#
#   scripts/demo/outcome-footer.sh          bridge tests (pnpm test), DSHKit LastTurnTests,
#                                OutcomeFooterUITests, then the seams:
#                                OutcomesUITests (done and failed) and DrawerMotionUITests
#                                (landing positions)
#   DSHM_RESUME=1               skip the parts that passed for the same code (lib.sh demo_part)
#
# Resources (WORKFLOW.md §6), read from the environment:
#   DSHM_SIM dshm-outcome-footer   DSHM_DD (DerivedData) /tmp/dshm-outcome-footer-dd
#   (DSHM_BRIDGE_PORT 47810, DSHM_WEB_PORT 3283, DSHM_HOME ~/.dshm/home-outcome-footer are unused here.)
# Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
for a in "$@"; do echo "unknown arg $a" >&2; exit 2; done
export DSHM_SIM="${DSHM_SIM:-dshm-outcome-footer}" DSHM_DD="${DSHM_DD:-/tmp/dshm-outcome-footer-dd}"
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

ui_part s27 OutcomeFooterUITests
# The seams: the outcomes demo's done and failed pages, and the drawer motion's landing positions (both land at the answer's start).
ui_part outcomes-seam OutcomesUITests
ui_part drawer-motion-seam DrawerMotionUITests

step "outcome-footer demo passed"
