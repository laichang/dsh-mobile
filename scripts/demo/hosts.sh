#!/bin/bash
# The hosts sheet (H) and the all-offline card (X3) on FakeBridge hosts (DESIGN.md screens H, X3;
# ARCHITECTURE D134). `-DSHMFakeBridge hosts` has MacBook-Pro (online, with a model catalog),
# hk-1 (its DSH is too old) and 公司-PC; the UI tests stop and start them with Darwin
# notifications (`FakeHostsSwitch`).
#
#   scripts/demo/hosts.sh          swift test, the hosts UI tests, and the seams: the FakeHosts
#                                  revoke tests (S29), the offline FakeBridge card (S2), the
#                                  new-session page (T1), and scripts/demo/bridge-errors.sh (the
#                                  card and the row with each host's reason, on real DSH)
#   scripts/demo/hosts.sh --shots  also refresh the screenshots in evidence/S11/ (1/3 size)
#   DSHM_RESUME=1                  skip the parts that passed for the same code (lib.sh demo_part)
#
# Resources (scripts/slice-env): DSHM_SIM, DSHM_DD; DSHM_BRIDGE_PORT, DSHM_WEB_PORT and DSHM_HOME
# go to the bridge-errors seam only (the hosts are in-process fakes).
# Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0
for a in "$@"; do case "$a" in --shots) SHOTS=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done
export DSHM_BRIDGE_PORT="${DSHM_BRIDGE_PORT:-47800}" DSHM_WEB_PORT="${DSHM_WEB_PORT:-3283}"
export DSHM_HOME="${DSHM_HOME:-$HOME/.dshm/home}"
export DSHM_SIM="${DSHM_SIM:-iPhone 17 Pro}" DSHM_DD="${DSHM_DD:-/tmp/dshm-hosts-dd}"
NODE24="$HOME/.nvm/versions/node/v24.14.0/bin"
[ -d "$NODE24" ] && export PATH="$NODE24:$PATH"
step() { printf '\n== %s\n' "$*"; }
SIM="$DSHM_SIM"
source scripts/demo/lib.sh
LOGS=/tmp/dshm-hosts-$DSHM_BRIDGE_PORT; mkdir -p "$LOGS"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
SHOT_DIR="$(mktemp -d)"
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR"
trap 'rm -rf "$SHOT_DIR"' EXIT

step "DSHKit tests: the FakeHosts hosts and their catalog (swift test)"
demo_part hosts-swift-test swift test --package-path ios/DSHKit --filter HostsControlTests

step "build the app and UI tests ($SIM)"
xcodebuild build-for-testing -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DSHM_DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  > "$LOGS/build.log" 2>&1 || { grep -E "error:" "$LOGS/build.log"; exit 1; }

ui_part() { # name, then -only-testing selectors
  local name=$1; shift
  local args=() t
  for t in "$@"; do args+=("-only-testing:dsh-mobileUITests/$t"); done
  step "UI: $name (log: $LOGS/ui-$name.log)"
  if demo_part "ui-$name" xcodebuild test-without-building -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile \
      -destination "$DEST" -derivedDataPath "$DSHM_DD" -parallel-testing-enabled NO "${args[@]}" \
      > "$LOGS/ui-$name.log" 2>&1; then
    grep -E "Test Case.*(passed|failed|skipped)" "$LOGS/ui-$name.log" || true
  else
    grep -E "error:|Test Case.*(passed|failed)" "$LOGS/ui-$name.log" || tail -30 "$LOGS/ui-$name.log"
    echo "UI tests failed: $name" >&2
    exit 1
  fi
  demo_no_skipped_ui "$LOGS/ui-$name.log"
}

ui_part hosts S21HostsUITests

ui_part hosts-seams \
  S29RevokeUITests/testRevokedHostLeavesTheDrawerAndIsNotRetried \
  S29RevokeUITests/testRevokedLastHostOpens08 \
  S2DurableListUITests/testOfflineHostIsNamedWithFakeBridge \
  T1ShellUITests/testKeyboardGoesAwayOnTapOrSwipeDown

step "seam: scripts/demo/bridge-errors.sh (log: $LOGS/bridge-errors.log)"
demo_part hosts-bridge-errors env DSHM_DD="$DSHM_DD" scripts/demo/bridge-errors.sh > "$LOGS/bridge-errors.log" 2>&1 \
  || { tail -30 "$LOGS/bridge-errors.log"; echo "bridge-errors seam failed" >&2; exit 1; }
grep -E "Test Case.*(passed|failed|skipped)" "$LOGS/bridge-errors.log" || true
tail -2 "$LOGS/bridge-errors.log"

if [ $SHOTS = 1 ]; then
  step "screenshots → evidence/S11 (1/3 size)"
  mkdir -p evidence/S11
  for f in "$SHOT_DIR"/s21-*.png; do
    [ -e "$f" ] || { echo "no new shots (the UI part was skipped)"; break; }
    out="evidence/S11/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
step "hosts demo passed"
