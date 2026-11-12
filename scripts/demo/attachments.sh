#!/bin/bash
# Attachments demo and checks: attach one photo on composer 01, send a
# task, and the DSH session has the image. With --all, also files: a photo, a .txt and a .pdf on 01
# with one removed, and a file on a follow-up, and the DSH sessions have them.
#
#   scripts/demo/attachments.sh          bridge tests + DSHKit tests (golden photo, files), then
#                                        AttachmentsUITests/testAttachOnePhotoAndSend on a real DSH
#                                        + bridge with the mock model, then a check of the DSH
#                                        session log for the image
#   scripts/demo/attachments.sh --all    also testAttachPhotoTextAndPDFRemoveOneAndSend and
#                                        testAttachFileToFollowUp, then a check of the DSH session
#                                        logs for the files (attachments-files-check.mjs)
#   scripts/demo/attachments.sh --shots DIR  also write the screenshots (1/3 size) into DIR
#   DSHM_RESUME=1                        skip the parts that passed for the same code (lib.sh demo_part)
#
# The golden photo (protocol/fixtures/attachments/photo.jpg) is added to the simulator's photo
# library first, so the picker shows it as the newest photo. With --all, the files of
# scripts/demo/attachments-files/ are put in Files > On My iPhone (the Files app's local storage).
#
# Resources, read from the environment (scripts/slice-env):
#   DSHM_SIM, DSHM_DD (DerivedData, default /tmp/dshm-attachments-dd), DSHM_BRIDGE_PORT,
#   DSHM_WEB_PORT, DSHM_HOME. Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=""
ALL=0
while [ $# -gt 0 ]; do case "$1" in
  --shots) SHOTS="${2:?--shots needs a directory}"; shift 2 ;;
  --all) ALL=1; shift ;;
  *) echo "unknown arg $1" >&2; exit 2 ;;
esac; done
FILES="$ROOT/scripts/demo/attachments-files"
: "${DSHM_SIM:?run eval \"\$(scripts/slice-env <ID>)\" first}"
: "${DSHM_BRIDGE_PORT:?}" "${DSHM_WEB_PORT:?}" "${DSHM_HOME:?}"
export DSHM_DD="${DSHM_DD:-/tmp/dshm-attachments-dd}"
NODE24="$HOME/.nvm/versions/node/v24.14.0/bin"
[ -d "$NODE24" ] && export PATH="$NODE24:$PATH"
[ -d "$HOME/.dshm/bin" ] && export PATH="$HOME/.dshm/bin:$PATH"
step() { printf '\n== %s\n' "$*"; }
source scripts/demo/lib.sh
demo_tls_home
LOGS="/tmp/dshm-attachments-${DSHM_BRIDGE_PORT:-47801}"; mkdir -p "$LOGS"
SIM="$DSHM_SIM"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
SHOT_DIR="$(mktemp -d)"
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR"

demo_prepare_bridge
step "bridge tests (node:test, FakeDSH, golden photo)"
demo_part attachments-bridge-test bash -c 'source scripts/demo/lib.sh; demo_bridge_tests "$1"' _ "$LOGS/bridge-test.log"
step "DSHKit tests (swift test, FakeBridge, golden photo)"
demo_part attachments-swift-test bash -c 'source scripts/demo/lib.sh; demo_swift_tests "$1"' _ "$LOGS/swift-test.log"

step "build the app and UI tests ($SIM)"
scripts/xc build-for-testing -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DSHM_DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  --log "$LOGS/build.log" || { grep -E "error:" "$LOGS/build.log"; exit 1; }

step "the golden photo into the simulator's library"
xcrun simctl addmedia "$SIM" protocol/fixtures/attachments/photo.jpg
if [ $ALL = 1 ]; then
  step "the demo files into Files > On My iPhone"
  # The Files app's local storage is an app group of com.apple.DocumentsApp.
  LOCAL="$(xcrun simctl get_app_container "$SIM" com.apple.DocumentsApp groups \
    | awk -F'\t' '$1 == "group.com.apple.FileProvider.LocalStorage" { print $2 }')"
  [ -d "$LOCAL" ] || { echo "no Files local storage on $SIM" >&2; exit 1; }
  mkdir -p "$LOCAL/File Provider Storage"
  cp "$FILES"/notes.txt "$FILES"/report.pdf "$LOCAL/File Provider Storage/"
  ls -l "$LOCAL/File Provider Storage/"
fi

DSH_PID=""
demo_tls_on_exit '[ -n "$DSH_PID" ] && kill "$DSH_PID" 2>/dev/null || true'
(cd bridge && corepack pnpm build >/dev/null)
step "real DSH + bridge (web $DSHM_WEB_PORT, bridge $DSHM_BRIDGE_PORT, $DSHM_HOME)"
mkdir -p "$DSHM_HOME"
if lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null 2>&1; then echo "port $DSHM_BRIDGE_PORT is in use" >&2; exit 1; fi
node scripts/dsh-up.mjs > "$LOGS/dsh-up.log" 2>&1 &
DSH_PID=$!
for _ in $(seq 1 240); do lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.5; done
lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null || { tail -20 "$LOGS/dsh-up.log"; echo "bridge did not come up" >&2; exit 1; }
SINCE="$(date +%s)"

step "UI: attach one photo on 01 and send (log: $LOGS/ui.log)"
export TEST_RUNNER_DSHM_REAL_DSH=1 TEST_RUNNER_DSHM_BRIDGE_PORT="$DSHM_BRIDGE_PORT"
if demo_part attachments-ui demo_tls_ui test-without-building -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile \
    -destination "$DEST" -derivedDataPath "$DSHM_DD" -parallel-testing-enabled NO \
    -only-testing:dsh-mobileUITests/AttachmentsUITests/testRetryAfterUploadFailureKeepsPhotoAndDraft \
    -only-testing:dsh-mobileUITests/AttachmentsUITests/testAttachOnePhotoAndSend --log "$LOGS/ui.log"; then
  grep -E "Test Case.*(passed|failed|skipped)" "$LOGS/ui.log" || true
else
  grep -E "error:|Test Case.*(passed|failed)" "$LOGS/ui.log" || tail -30 "$LOGS/ui.log"
  echo "UI test failed" >&2; exit 1
fi
demo_no_skipped_ui "$LOGS/ui.log"

step "the DSH session has the image"
# A UI part skipped for the same code (DSHM_RESUME) made its session in an earlier run.
grep -q "Test Case.*passed" "$LOGS/ui.log" || SINCE=0
# The prompt of AttachmentsUITests, and the size of the golden photo (the app keeps it under 2048 px).
node scripts/demo/attachments-check.mjs "$DSHM_HOME" "$SINCE" "What is in this photo?" 480x360

if [ $ALL = 1 ]; then
  SINCE="$(date +%s)"
  step "UI: a photo, a .txt and a .pdf on 01, one removed; a file on a follow-up (log: $LOGS/ui-files.log)"
  if demo_part attachments-ui-files demo_tls_ui test-without-building -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile \
      -destination "$DEST" -derivedDataPath "$DSHM_DD" -parallel-testing-enabled NO \
      -only-testing:dsh-mobileUITests/AttachmentsUITests/testAttachPhotoTextAndPDFRemoveOneAndSend \
      -only-testing:dsh-mobileUITests/AttachmentsUITests/testAttachFileToFollowUp --log "$LOGS/ui-files.log"; then
    grep -E "Test Case.*(passed|failed|skipped)" "$LOGS/ui-files.log" || true
  else
    grep -E "error:|Test Case.*(passed|failed)" "$LOGS/ui-files.log" || tail -30 "$LOGS/ui-files.log"
    echo "UI test failed" >&2; exit 1
  fi
  demo_no_skipped_ui "$LOGS/ui-files.log"

  step "the DSH sessions have the files"
  # A UI part skipped for the same code (DSHM_RESUME) made its sessions in an earlier run.
  grep -q "Test Case.*passed" "$LOGS/ui-files.log" || SINCE=0
  node scripts/demo/attachments-files-check.mjs "$DSHM_HOME" "$SINCE" "$FILES"
fi
kill "$DSH_PID" 2>/dev/null || true; wait "$DSH_PID" 2>/dev/null || true; DSH_PID=""

if [ -n "$SHOTS" ]; then
  step "screenshots → $SHOTS (1/3 size)"
  mkdir -p "$SHOTS"
  for f in "$SHOT_DIR"/attachments-*.png; do
    [ -e "$f" ] || { echo "no new shots (the UI part was skipped)"; break; }
    out="$SHOTS/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
step "attachments demo passed"
