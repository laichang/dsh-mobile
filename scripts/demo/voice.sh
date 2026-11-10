#!/bin/bash
# Voice input demo and checks: the mic key on the composer of 01 and of
# the session page, with the fake transcriber (-DSHMFakeSpeech) and the FakeBridge. App only: no
# DSH and no bridge.
#
#   scripts/demo/voice.sh              DSHKit DictationTests (swift test), then VoiceUITests:
#                                      testDictateATaskThenAFollowUpAndSend (the mic fills the field,
#                                      send starts the task with that text; the same on the session
#                                      page after typed text) and
#                                      testDeniedSpeechSaysHowToTurnItOnAndKeepsTheField, then
#                                      testRealPermissionPromptsDoNotCrashTheApp (the real Speech
#                                      framework's permission prompts, answered on the system's
#                                      queue: allow speech, turn off the microphone)
#   scripts/demo/voice.sh --shots DIR  also write the screenshots (1/3 size) into DIR
#   DSHM_RESUME=1                      skip the parts that passed for the same code (lib.sh demo_part)
#
# Resources (WORKFLOW.md §6), read from the environment (scripts/slice-env): DSHM_SIM, DSHM_DD
# (DerivedData, default /tmp/dshm-voice-dd). Fails on any failed or skipped test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=""
while [ $# -gt 0 ]; do case "$1" in
  --shots) SHOTS="${2:?--shots needs a directory}"; shift 2 ;;
  *) echo "unknown arg $1" >&2; exit 2 ;;
esac; done
: "${DSHM_SIM:?run eval \"\$(scripts/slice-env <ID>)\" first}"
export DSHM_DD="${DSHM_DD:-/tmp/dshm-voice-dd}"
step() { printf '\n== %s\n' "$*"; }
source scripts/demo/lib.sh
LOGS=/tmp/dshm-voice-$(basename "$DSHM_SIM"); mkdir -p "$LOGS"
SIM="$DSHM_SIM"
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
SHOT_DIR="$(mktemp -d)"
trap 'rm -rf "$SHOT_DIR"' EXIT
export TEST_RUNNER_DSHM_SHOT_DIR="$SHOT_DIR"

step "DSHKit DictationTests and SystemCallbackTests (swift test, FakeTranscriber; log: $LOGS/swift-test.log)"
demo_part voice-swift-test bash -c '
  scripts/swift-test --package-path ios/DSHKit --filter "DictationTests|SystemCallbackTests" --log "$1" || exit 1
  if grep -qE "Test .* skipped|[1-9][0-9]* tests? skipped" "$1"; then echo "swift tests were skipped" >&2; exit 1; fi' _ "$LOGS/swift-test.log"

step "build the app and UI tests ($SIM)"
scripts/xc build-for-testing -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$DEST" \
  -derivedDataPath "$DSHM_DD" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  --log "$LOGS/build.log" || { grep -E "error:" "$LOGS/build.log"; exit 1; }

ui() { # name test log
  local name=$1 test=$2 log=$3
  if demo_part "$name" scripts/xc test-without-building -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile \
      -destination "$DEST" -derivedDataPath "$DSHM_DD" -parallel-testing-enabled NO \
      -only-testing:"dsh-mobileUITests/VoiceUITests/$test" --log "$log"; then
    grep -E "Test Case.*(passed|failed|skipped)" "$log" || true
  else
    grep -E "error:|Test Case.*(passed|failed)" "$log" || tail -30 "$log"
    echo "UI test failed ($log)" >&2; exit 1
  fi
  demo_no_skipped_ui "$log"
}

step "UI: dictate a task on 01 and send; dictate after typed text on the session page and send (log: $LOGS/ui-dictate.log)"
ui voice-ui-dictate testDictateATaskThenAFollowUpAndSend "$LOGS/ui-dictate.log"

step "UI: speech permission denied (log: $LOGS/ui-denied.log)"
ui voice-ui-denied testDeniedSpeechSaysHowToTurnItOnAndKeepsTheField "$LOGS/ui-denied.log"

step "UI: the real permission prompts do not crash the app (log: $LOGS/ui-real-permission.log)"
ui voice-ui-real-permission testRealPermissionPromptsDoNotCrashTheApp "$LOGS/ui-real-permission.log"

if [ -n "$SHOTS" ]; then
  step "screenshots → $SHOTS (1/3 size)"
  mkdir -p "$SHOTS"
  for f in "$SHOT_DIR"/voice-*.png; do
    [ -e "$f" ] || { echo "no new shots (the UI parts were skipped)"; break; }
    out="$SHOTS/$(basename "$f")"
    sips --resampleWidth 402 "$f" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
fi
step "voice demo passed"
