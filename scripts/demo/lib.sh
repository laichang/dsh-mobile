# Shared by scripts/demo/<slice>.sh (source it after `cd "$ROOT"` and setting PATH).
# Each check fails the demo on a failed *or skipped* test, so a demo can't pass by not running.
#   demo_prepare_bridge   pnpm install (first, so a fresh clone has buf), then `scripts/codegen --check`
#   demo_bridge_tests LOG node:test suite; prints the summary
#   demo_swift_tests LOG  `swift test` in ios/DSHKit; prints suites and the summary
#   demo_no_skipped_ui LOG  fails if an XCUITest in LOG was skipped

demo_prepare_bridge() {
  printf '\n== %s\n' "bridge dependencies (pnpm install --frozen-lockfile)"
  (cd bridge && corepack pnpm install --frozen-lockfile >/dev/null)
  printf '\n== %s\n' "codegen is up to date"
  scripts/codegen --check
}

demo_bridge_tests() {
  local log=$1
  (cd bridge && corepack pnpm test) > "$log" 2>&1 || { tail -40 "$log"; echo "bridge tests failed" >&2; return 1; }
  # node:test prints a spec summary (ℹ pass N) or a TAP one (# pass N), depending on the version.
  grep -E "^(ℹ|#) (tests|pass|fail|skipped|todo) " "$log"
  if grep -qE "^(ℹ|#) (skipped|todo) [1-9]" "$log"; then echo "bridge tests were skipped" >&2; return 1; fi
}

demo_swift_tests() {
  local log=$1
  swift test --package-path ios/DSHKit > "$log" 2>&1 || { grep -E "✘|error:" "$log" | head -40; echo "swift tests failed" >&2; return 1; }
  grep -E "✔ Suite|Test run" "$log"
  if grep -qE "Test .* skipped|[1-9][0-9]* tests? skipped" "$log"; then echo "swift tests were skipped" >&2; return 1; fi
}

demo_no_skipped_ui() {
  local log=$1
  if grep -qE "Test Case.*skipped|with [1-9][0-9]* tests? skipped" "$log"; then
    grep -E "Test Case.*skipped" "$log"
    echo "UI tests were skipped ($log)" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------------------------
# Machine guard (WORKFLOW.md §6.1). Runs when this file is sourced. Rules that live in code, not
# in a prompt:
#   - Waits while the CPU is less than DSHM_MIN_IDLE (15) percent idle, then fails.
#   - Waits while DSHM_SIM_LIMIT (3) other dshm-* simulators are booted, then fails.
#   - When the top-level script exits (also on error or kill), shuts down its simulator if it is
#     a dshm-* simulator or was not booted before. A simulator of the user stays as it was.
#   - Boots a dshm-* simulator and stops the iOS services in DSHM_SIM_NOISE (dshm_quiet_sim).
# A nested demo (t1.sh --all runs s1.sh … s13.sh) sees DSHM_GUARD_OWNER and skips the guard; the
# top-level script owns the simulator. Env: DSHM_SIM_LIMIT (3), DSHM_GUARD_WAIT (seconds, 1800).

# CPU idle percent, from a 2-second sample. Not the load average: on macOS it also counts
# threads that only wait, and it showed 139 on 12 CPUs while the CPU was 75% idle (2026-11-06).
dshm_cpu_idle() {
  top -l 2 -s 2 -n 0 2>/dev/null | awk '/CPU usage/ { v = $7 } END { sub(/%/, "", v); print v + 0 }'
}

dshm_load_ok() {
  awk -v i="$(dshm_cpu_idle)" -v m="${DSHM_MIN_IDLE:-15}" 'BEGIN { exit !(i >= m) }'
}

# Booted dshm-* simulators other than $1 (name or UDID), one "name (udid)" per line.
dshm_other_sims() {
  xcrun simctl list devices booted 2>/dev/null \
    | sed -nE 's/^ +(dshm-[^ ]+) \(([0-9A-F-]{36})\) \(Booted\).*/\1 \2/p' \
    | awk -v me="$1" '$1 != me && $2 != me { print $1 " (" $2 ")" }'
}

dshm_sim_booted() {
  xcrun simctl list devices booted 2>/dev/null | grep -qE "^ +$1 \(|\($1\) \(Booted\)"
}

# iOS background services that use most of the CPU in a test simulator and that no test needs.
# Measured 2026-11-06: mediaanalysisd alone used 5+ CPUs of a fresh dshm-* simulator, and the
# 1-minute load went to 290 on 12 CPUs. With these stopped, the load went down to 13.
DSHM_SIM_NOISE="com.apple.mediaanalysisd com.apple.photoanalysisd com.apple.mlhostd
  com.apple.managedappdistributiond com.apple.knowledgeconstructiond com.apple.intelligenceplatformd
  com.apple.spotlightknowledged com.apple.siriactionsd com.apple.siriknowledged com.apple.siriinferenced"

# Boot $1 and stop the services in DSHM_SIM_NOISE in it. The simulator does not keep a disabled
# service after a reboot, so this runs on each boot. xcodebuild uses a booted simulator as it is.
dshm_quiet_sim() {
  local sim=$1 l
  # Only a dshm-* simulator (by name or UDID). A simulator of the user stays as it was.
  case "$sim" in
    dshm-*) ;;
    *) xcrun simctl list devices 2>/dev/null | grep -qE "^ +dshm-[^ ]+ \\($sim\\)" || return 0 ;;
  esac
  xcrun simctl boot "$sim" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$sim" -b >/dev/null 2>&1 || { echo "guard: $sim did not boot" >&2; return 1; }
  for l in $DSHM_SIM_NOISE; do
    xcrun simctl spawn "$sim" launchctl disable "system/$l" >/dev/null 2>&1 || true
    xcrun simctl spawn "$sim" launchctl bootout "system/$l" >/dev/null 2>&1 || true
  done
}

dshm_guard() {
  local sim=$1 limit=${DSHM_SIM_LIMIT:-3} wait=${DSHM_GUARD_WAIT:-1800} waited=0 others n
  while :; do
    others=$(dshm_other_sims "$sim")
    n=$(printf '%s' "$others" | grep -c . || true)
    if dshm_load_ok && [ "$n" -lt "$limit" ]; then break; fi
    if [ "$waited" -ge "$wait" ]; then
      echo "guard: the Mac is not ready after ${wait}s (WORKFLOW.md §6.1)." >&2
      echo "guard: CPU $(dshm_cpu_idle)% idle, minimum ${DSHM_MIN_IDLE:-15}%" >&2
      echo "guard: other booted dshm-* simulators ($n, limit $limit):" >&2
      printf '%s\n' "$others" | sed 's/^/  /' >&2
      echo "guard: shut down the simulators that no running slice uses. Do not raise the limit." >&2
      return 1
    fi
    [ "$waited" = 0 ] && echo "guard: waiting (CPU $(dshm_cpu_idle)% idle, $n other dshm-* simulators booted)" >&2
    sleep 30; waited=$((waited + 30))
  done
  # Shut the simulator down when the owner exits. A watcher process, so a script's own
  # `trap … EXIT` does not replace it, and a killed script still gets it.
  local shut=0
  case "$sim" in dshm-*) shut=1 ;; esac
  dshm_sim_booted "$sim" || shut=1
  if [ $shut = 1 ]; then
    nohup bash -c 'while kill -0 "$1" 2>/dev/null; do sleep 3; done; xcrun simctl shutdown "$2" >/dev/null 2>&1' \
      dshm-guard "$$" "$sim" >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
  dshm_quiet_sim "$sim"
}

# No simulator (bridge-only scripts such as scripts/ci/bridge-upstream) or no Xcode: no guard.
if [ -z "${DSHM_GUARD_OWNER:-}" ] && [ -n "${SIM:-${DSHM_SIM:-}}" ] && command -v xcrun >/dev/null 2>&1; then
  export DSHM_GUARD_OWNER=$$
  dshm_guard "${SIM:-${DSHM_SIM:-}}" || exit 1
fi

# ---------------------------------------------------------------------------------------------
# Parts that resume (WORKFLOW.md §10.1). A script that runs many parts wraps each one:
#   demo_part <name> <command…>
# A part that passed is recorded for the current code (HEAD + uncommitted diff). With
# DSHM_RESUME=1, a part that passed for the same code is skipped, so a failure in part 9 of 14
# does not run parts 1–8 again. DSHM_PART_RETRIES (0) runs a failed part again that many times;
# a part that passes on a retry is written to the flaky list (<state>/<code>/flaky.txt).
# <command> must be a script or program, not a shell function: `set -e` does not apply inside an
# `if`, so a function would not stop at its first error.

# evidence/ is not code: slice demos rewrite their shots while a run goes on.
dshm_code_key() {
  { git rev-parse HEAD; git diff HEAD -- . ':!evidence'; } | shasum -a 256 | cut -c1-16
}

demo_part() {
  local name=$1; shift
  local dir="${DSHM_STATE:-/tmp/dshm-state/$(basename "$(git rev-parse --show-toplevel)")}/$(dshm_code_key)"
  local tries=$(( ${DSHM_PART_RETRIES:-0} + 1 )) i
  mkdir -p "$dir"
  if [ "${DSHM_RESUME:-0}" = 1 ] && [ -f "$dir/$name.ok" ]; then
    printf '\n== part %s: skip, it passed for this code\n' "$name"; return 0
  fi
  rm -f "$dir/$name.has-parts"
  [ -n "${DSHM_PART_PARENT:-}" ] && touch "$dir/$DSHM_PART_PARENT.has-parts"
  for i in $(seq 1 "$tries"); do
    # A retry skips the inner parts that passed. A part whose command has its own parts does not
    # retry: the inner parts did their retries already.
    if [ "$i" -gt 1 ] && [ -f "$dir/$name.has-parts" ]; then break; fi
    local resume=${DSHM_RESUME:-0}; [ "$i" -gt 1 ] && resume=1
    if DSHM_RESUME=$resume DSHM_PART_PARENT=$name "$@"; then
      touch "$dir/$name.ok"
      if [ "$i" -gt 1 ]; then
        echo "$name passed on run $i of $tries" >> "$dir/flaky.txt"
        printf '\n== part %s: FLAKY, passed on run %s\n' "$name" "$i"
      fi
      return 0
    fi
    if [ "$i" -lt "$tries" ] && [ ! -f "$dir/$name.has-parts" ]; then
      printf '\n== part %s: failed on run %s, run it again\n' "$name" "$i"
    fi
  done
  printf '\n== part %s: FAILED\n' "$name"
  return 1
}
