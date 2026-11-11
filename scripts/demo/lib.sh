# Shared by scripts/demo/<feature>.sh (source it after `cd "$ROOT"` and setting PATH).
# Each check fails the demo on a failed *or skipped* test, so a demo can't pass by not running.
#   demo_prepare_bridge   pnpm install (first, so a fresh clone has buf), then `scripts/codegen --check`
#   demo_bridge_tests LOG node:test suite (scripts/pnpm-test); prints the JSON summary
#   demo_swift_tests LOG  `swift test` in ios/DSHKit (scripts/swift-test); prints the JSON summary
#   demo_no_skipped_ui LOG  fails if an XCUITest in LOG was skipped

demo_prepare_bridge() {
  printf '\n== %s\n' "bridge dependencies (pnpm install --frozen-lockfile)"
  (cd bridge && corepack pnpm install --frozen-lockfile >/dev/null)
  printf '\n== %s\n' "codegen is up to date"
  scripts/codegen --check
}

demo_bridge_tests() {
  local log=$1
  scripts/pnpm-test --log "$log" || { echo "bridge tests failed" >&2; return 1; }
  # node:test prints a spec summary (ℹ pass N) or a TAP one (# pass N), depending on the version.
  if grep -qE "^(ℹ|#) (skipped|todo) [1-9]" "$log"; then echo "bridge tests were skipped" >&2; return 1; fi
}

demo_swift_tests() {
  local log=$1
  scripts/swift-test --log "$log" --package-path ios/DSHKit || { echo "swift tests failed" >&2; return 1; }
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
# Machine guard. Runs when this file is sourced. Rules that live in code, not
# in a prompt:
#   - Refuses at once when the data volume has less than DSHM_MIN_FREE_GB (30) GB free.
#   - Waits while the CPU is less than DSHM_MIN_IDLE (15) percent idle, then fails.
#   - Waits while DSHM_SIM_LIMIT (3) other dshm-* simulators are booted, then fails.
#   - When the top-level script exits (also on error or kill), shuts down its simulator if it is
#     a dshm-* simulator or was not booted before. A simulator of the user stays as it was.
#   - Boots a dshm-* simulator and stops the iOS services in DSHM_SIM_NOISE (dshm_quiet_sim).
# A nested demo (shell.sh --all runs pairing.sh … session-visibility.sh) sees DSHM_GUARD_OWNER and skips the guard; the
# top-level script owns the simulator. Env: DSHM_SIM_LIMIT (3), DSHM_GUARD_WAIT (seconds, 1800),
# DSHM_MIN_FREE_GB (30). Bridge-only scripts (no simulator, also on CI runners) skip the guard.

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

# Owner records: $DSHM_OWNERS/<sim> holds "<pid> <process start time>" of the script that owns
# the simulator. The watcher removes it after the shutdown.
DSHM_OWNERS="${DSHM_OWNERS:-/tmp/dshm-guard}"

dshm_pid_start() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ /_/g'; }

# Shut down each booted dshm-* simulator whose owner is gone (killed with its watcher, or the
# watcher is gone). A simulator with no owner record stays as it is.
dshm_reap_orphans() {
  local f sim pid start
  [ -d "$DSHM_OWNERS" ] || return 0
  for f in "$DSHM_OWNERS"/*; do
    [ -f "$f" ] || continue
    sim=$(basename "$f"); read -r pid start < "$f" || continue
    [ -n "$pid" ] && [ "$(dshm_pid_start "$pid")" = "$start" ] && continue
    if dshm_sim_booted "$sim"; then
      echo "guard: $sim has no owner now (pid $pid ended); shutting it down" >&2
      xcrun simctl shutdown "$sim" >/dev/null 2>&1 || true
    fi
    rm -f "$f"
  done
}

# Free space floor. A simulator takes 2-4 GB and a DerivedData copy 1-3 GB. On 2026-11-08 the data
# volume had 8.3 GB free after the run left 23 simulators, 30 worktrees and ~230 /tmp/dshm-* dirs.
# Free KB on the volume that holds $HOME (/System/Volumes/Data on macOS). DSHM_FREE_KB replaces
# the measurement (tests only).
dshm_free_kb() {
  if [ -n "${DSHM_FREE_KB:-}" ]; then echo "$DSHM_FREE_KB"; return; fi
  df -kP "$HOME" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

# Refuses (one line on stderr, exit 1) when free space is below DSHM_MIN_FREE_GB (30). It does not
# wait: space does not come back by itself.
dshm_disk_ok() {
  local kb floor=${DSHM_MIN_FREE_GB:-30} mount
  kb=$(dshm_free_kb)
  [ -n "$kb" ] || return 0   # no measurement: do not block
  if [ "$kb" -lt $((floor * 1024 * 1024)) ]; then
    mount=$(df -kP "$HOME" 2>/dev/null | awk 'NR == 2 { print $6 }')
    echo "guard: $((kb / 1024 / 1024)) GB free on ${mount:-the data volume}, below the floor of $floor GB (DSHM_MIN_FREE_GB). Next: remove the leftovers that scripts/status lists (scripts/plan cleanup <ID>), then run it again." >&2
    return 1
  fi
}

dshm_guard() {
  local sim=$1 limit=${DSHM_SIM_LIMIT:-3} wait=${DSHM_GUARD_WAIT:-1800} waited=0 others n
  # Before anything boots or builds.
  dshm_disk_ok || return 1
  while :; do
    dshm_reap_orphans
    others=$(dshm_other_sims "$sim")
    n=$(printf '%s' "$others" | grep -c . || true)
    if dshm_load_ok && [ "$n" -lt "$limit" ]; then break; fi
    if [ "$waited" -ge "$wait" ]; then
      echo "guard: the Mac is not ready after ${wait}s. Next: wait, or stop other demos and builds (scripts/status lists them)." >&2
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
  # `trap … EXIT` does not replace it, and a killed script still gets it. The watcher runs in its
  # own session, outside the process tree of the owner: a tool that stops a background job kills
  # its whole process group or tree, and a plain `nohup … &` died with it (2026-11-06).
  local shut=0
  case "$sim" in dshm-*) shut=1 ;; esac
  dshm_sim_booted "$sim" || shut=1
  if [ $shut = 1 ]; then
    mkdir -p "$DSHM_OWNERS"
    printf '%s %s\n' "$$" "$(dshm_pid_start $$)" > "$DSHM_OWNERS/$sim"
    perl -MPOSIX -e 'exit 0 if fork; POSIX::setsid(); exit 0 if fork; open STDIN, "</dev/null";
      open STDOUT, ">/dev/null"; open STDERR, ">&STDOUT"; exec @ARGV' \
      bash -c 'while kill -0 "$1" 2>/dev/null; do sleep 3; done
        # A new owner of the same simulator took over: leave it to that owner.
        [ "$(cut -d" " -f1 "$3" 2>/dev/null)" = "$1" ] || exit 0
        xcrun simctl shutdown "$2" >/dev/null 2>&1; rm -f "$3"' \
      dshm-guard "$$" "$sim" "$DSHM_OWNERS/$sim"
  fi
  dshm_quiet_sim "$sim"
}

# No simulator (bridge-only scripts such as scripts/ci/bridge-upstream) or no Xcode: no guard.
if [ -z "${DSHM_GUARD_OWNER:-}" ] && [ -n "${SIM:-${DSHM_SIM:-}}" ] && command -v xcrun >/dev/null 2>&1; then
  export DSHM_GUARD_OWNER=$$
  dshm_guard "${SIM:-${DSHM_SIM:-}}" || exit 1
fi

# ---------------------------------------------------------------------------------------------
# Parts that resume. A script that runs many parts wraps each one:
#   demo_part <name> <command…>
# A part that passed is recorded for the current code (the content of the worktree). With
# DSHM_RESUME=1, a part that passed for the same code is skipped, so a failure in part 9 of 14
# does not run parts 1–8 again. DSHM_PART_RETRIES (0) runs a failed part again that many times;
# a part that passes on a retry is written to the flaky list (<state>/<code>/flaky.txt).
# <command> must be a script or program, not a shell function: `set -e` does not apply inside an
# `if`, so a function would not stop at its first error.

# The key is the git tree of the worktree content (tracked and untracked, not ignored), so a
# commit of the same content keeps the key. evidence/, plan/ and *.md are not code: slice demos
# rewrite their shots while a run goes on, and plan/ and the docs change after a run (evidence, logs).
dshm_code_key() {
  local idx
  idx=$(mktemp "${TMPDIR:-/tmp}/dshm-key.XXXXXX")
  cp "$(git rev-parse --path-format=absolute --git-path index)" "$idx"
  GIT_INDEX_FILE=$idx git add -A -- . >/dev/null 2>&1
  GIT_INDEX_FILE=$idx git rm -r -q --cached --ignore-unmatch -- evidence plan ':(glob)**/*.md' >/dev/null 2>&1
  GIT_INDEX_FILE=$idx git write-tree | cut -c1-16
  rm -f "$idx"
}

demo_part() {
  local name=$1; shift
  local dir="${DSHM_STATE:-/tmp/dshm-state/$(basename "$(git rev-parse --show-toplevel)")}/$(dshm_code_key)"
  local tries=$(( ${DSHM_PART_RETRIES:-0} + 1 )) i
  mkdir -p "$dir"
  # A new TLS fixture has fresh offers, sessions and devices. Recreate its UI state on a resumed run.
  if [ "$1" != demo_tls_ui ] && [ "${DSHM_RESUME:-0}" = 1 ] && [ -f "$dir/$name.ok" ]; then
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

# Keep the original handler in the owning shell so it can wait for its host and proxy.
# Preserve the demo's exit status and finish cleanup even if that handler reports an error.
demo_tls_on_exit() {
  trap "demo_tls_status=\$?
    {
      ${1:-:}
    } || demo_tls_status=\$?
    rm -rf -- \"\$demo_tls_profile\" || demo_tls_status=\$?
    exit \"\$demo_tls_status\"" EXIT
}

# Each network demo gets a disposable host profile. Nested demos get their own as well.
demo_tls_home() {
  local base="${DSHM_HOME:-${TMPDIR:-/tmp}}"
  mkdir -p "$base"
  demo_tls_profile="$(mktemp -d "$base/demo.XXXXXXXX")" || return 1
  export DSHM_HOME="$demo_tls_profile"
  local previous
  previous=$(trap -p EXIT)
  if [[ -n "$previous" ]]; then
    # Bash quotes its current handler as a reusable shell command.
    eval "${previous/#trap -- /demo_tls_on_exit }"
  else
    demo_tls_on_exit
  fi
}

# The simulator drives enrollment through the app's normal deep link. Hand off secrets in
# private files so xcodebuild's environment dump and XCTest's activity log contain only paths.
demo_tls_ui() (
  umask 077
  local handoff sim key value
  handoff=$(mktemp -d)
  sim="${SIM:-${DSHM_SIM:?set DSHM_SIM}}"
  export TEST_RUNNER_DSHM_TLS_HANDOFF="$handoff"
  for key in $(compgen -A variable TEST_RUNNER_DSHM_); do
    value=${!key}
    case "$value" in
      dshm://pair*)
        printf '%s' "$value" > "$handoff/${key#TEST_RUNNER_}"
        unset "$key"
        ;;
    esac
  done
  (
    while :; do
      if [[ -f "$handoff/enroll" ]]; then
        port=$(cat "$handoff/enroll")
        rm "$handoff/enroll"
        node bridge/lib/scripts/pair.js --url-only --state-dir "${DSHM_ENROLL_HOME:-$DSHM_HOME}/dsh-mobile-bridge" |
          node -e '
            const url = new URL(require("node:fs").readFileSync(0, "utf8").trim());
            if (url.searchParams.get("v") !== "2") process.exit(1);
            if (process.argv[1]) {
              const port = Number(process.argv[1]);
              if (!Number.isInteger(port) || port < 1 || port > 65535) process.exit(1);
              url.searchParams.set("a", "127.0.0.1:" + port);
            }
            process.stdout.write(url.href);
          ' "$port" > "$handoff/new" || exit 1
        mv "$handoff/new" "$handoff/open"
      fi
      if [[ -f "$handoff/open" ]]; then
        xcrun simctl openurl "$sim" "$(cat "$handoff/open")" >/dev/null 2>&1 || exit 1
        rm -f "$handoff/open"
      fi
      sleep 0.1
    done
  ) &
  local watcher=$!
  trap 'kill "$watcher" 2>/dev/null || true; wait "$watcher" 2>/dev/null || true; rm -rf "$handoff"' EXIT
  if [[ " $* " != *" -parallel-testing-enabled "* ]]; then set -- "$@" -parallel-testing-enabled NO; fi
  scripts/xc "$@"
)

demo_tls_client() (
  cd bridge
  node lib/test/demo-client.js "$1/dsh-mobile-bridge" "$2" "$3"
)
