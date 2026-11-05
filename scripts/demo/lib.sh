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
