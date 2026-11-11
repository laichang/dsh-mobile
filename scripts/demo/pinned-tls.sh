#!/bin/bash
# iOS TLS tracer: an isolated strict-ATS build and ephemeral loopback listeners.
set -euo pipefail
cd "$(dirname "$0")/../.."
export PATH="$HOME/.dshm/bin:$HOME/.nvm/versions/node/v24.14.0/bin:$PATH"
SIM="${DSHM_SIM:?set DSHM_SIM with scripts/slice-env}"
source scripts/demo/lib.sh
run=$(mktemp -d)
pid=""
cleanup() { if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi; rm -rf "$run"; }
trap cleanup EXIT
(cd bridge && corepack pnpm install --frozen-lockfile >/dev/null && corepack pnpm build)
(cd bridge && exec node lib/scripts/pinned-tls-fixture.js "$run") >"$run/peer.log" 2>&1 &
pid=$!
for _ in {1..100}; do
  [[ -s "$run/client.json" ]] && break
  kill -0 "$pid" 2>/dev/null || { cat "$run/peer.log"; exit 1; }
  sleep 0.1
done
export TEST_RUNNER_DSHM_TLS_FIXTURE="$(cat "$run/client.json")"
dd="${DSHM_DD:-/tmp/dshm-pinned-tls-$SIM-dd}"
dest="platform=iOS Simulator,id=$SIM"
plutil -create xml1 "$run/strict.plist"
args=(-project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -destination "$dest" -derivedDataPath "$dd"
      -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -parallel-testing-enabled NO)
scripts/xc build-for-testing "${args[@]}" "DSHM_DEBUG_APP_PLIST=$run/strict.plist"
products="$dd/Build/Products/Debug-iphonesimulator"
# Xcode ships its XCTest runner with arbitrary loads enabled. Apply the app's strict policy to this copy too.
runner="$products/dsh-mobileUITests-Runner.app"
if /usr/libexec/PlistBuddy -c 'Print NSAppTransportSecurity' "$runner/Info.plist" >/dev/null 2>&1; then
  plutil -remove NSAppTransportSecurity "$runner/Info.plist"
  codesign --force --sign - --preserve-metadata=entitlements "$runner"
fi
for plist in "$products/dsh-mobile.app/Info.plist" "$runner/Info.plist"; do
  [[ -s "$plist" ]]
  if /usr/libexec/PlistBuddy -c 'Print NSAppTransportSecurity' "$plist" >/dev/null 2>&1; then
    echo "TLS test product unexpectedly sets NSAppTransportSecurity: $plist" >&2; exit 1
  fi
done
scripts/xc test-without-building "${args[@]}" -only-testing:dsh-mobileUITests/PinnedTLSTests --log "$run/ui.log" ||
  { cat "$run/peer.log"; rg 'error:|failed|threw' "$run/ui.log" | tail -20; exit 1; }
rg -q 'testPinnedHelloAndRecovery.* passed' "$run/ui.log"
demo_no_skipped_ui "$run/ui.log"
node - "$run/counts.json" <<'JS'
const counts = require(process.argv[2])
const assert = require('node:assert/strict')
for (const [name, expected] of Object.entries({ip:1, renewed:2, redirect:1, destination:0,
  wrongKey:0, wrongName:0, expired:0, wrongUsage:0, oldTLS:0, cleartext:0})) assert.equal(counts[name], expected, name)
JS
echo "Pinned TLS 1.3 and recovery passed on iOS."
