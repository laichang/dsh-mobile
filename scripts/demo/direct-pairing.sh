#!/bin/bash
# Exercise replacement over pinned TLS with test credentials in the local Keychain.
set -euo pipefail
cd "$(dirname "$0")/../.."
export PATH="$HOME/.dshm/bin:$HOME/.nvm/versions/node/v24.14.0/bin:$PATH"
: "${DSHM_BRIDGE_PORT:?set the assigned bridge port}" "${DSHM_WEB_PORT:?set the assigned web port}"
umask 077
scratch=$(mktemp -d)
pid=''
cleanup() {
  if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" || true; fi
  rm -rf "$scratch"
}
trap cleanup EXIT
export DSHM_HOME="$scratch/host" DSHM_PAIRING_FIXTURE="$scratch"
for port in "$DSHM_BRIDGE_PORT" "$DSHM_WEB_PORT"; do
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null; then echo "Port $port is busy" >&2; exit 1; fi
done
(cd bridge && corepack pnpm install --offline --frozen-lockfile && corepack pnpm build)
node scripts/dsh-up.mjs >"$scratch/host.log" 2>&1 &
pid=$!
for _ in {1..240}; do
  lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null && break
  kill -0 "$pid" || { tail -20 "$scratch/host.log"; exit 1; }
  sleep 0.5
done
for n in 1 2 3; do
  (cd bridge && node lib/scripts/pair.js --url-only --state-dir "$DSHM_HOME/dsh-mobile-bridge") >"$scratch/offer-$n"
done
rsync -a --exclude=.build --exclude=.swiftpm ios/DSHKit/ "$scratch/DSHKit/"
cp scripts/demo/DirectPairingTests.swift "$scratch/DSHKit/Tests/DSHKitTests/"
for phase in terminateWhileReplacing restartAndRetryWithLockedKeychain; do
  scripts/swift-test --package-path "$scratch/DSHKit" --filter "DirectPairingTests/$phase" --log "$scratch/$phase.log"
  grep -Eq 'Test run with 1 test in [0-9]+ suite(s)? passed' "$scratch/$phase.log"
done
