#!/bin/bash
# Pair the selected iOS and bridge versions and exercise their command path against real DSH.
set -euo pipefail
cd "$(dirname "$0")/../.."
export PATH="$HOME/.dshm/bin:$HOME/.nvm/versions/node/v24.14.0/bin:$PATH"
: "${DSHM_SIM:?set the assigned simulator}" "${DSHM_BRIDGE_PORT:?set the assigned bridge port}"
scripts/slice-env --check-sim "$DSHM_SIM"
source scripts/demo/lib.sh
umask 077
scratch=$(mktemp -d)
pid=''
cleanup() {
  if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" || true; fi
  rm -rf "$scratch"
}
demo_tls_on_exit cleanup
baseline=61b54169a58e7a20e9ca243dc96a6739b816e14a
candidate=$(git rev-parse HEAD)
ios_rev=$baseline
bridge_rev=$candidate
case "${1:-}" in
  "") ;;
  --baseline-bridge) ios_rev=$candidate; bridge_rev=$baseline ;;
  --current-pair) ios_rev=$candidate ;;
  *) echo "usage: $0 [--baseline-bridge|--current-pair]" >&2; exit 2 ;;
esac
echo "iOS $ios_rev, bridge $bridge_rev"
git archive "$ios_rev" ios | tar -x -C "$scratch"
git archive "$bridge_rev" bridge spikes/x1-approval scripts/demo/approvals-host.mjs | tar -x -C "$scratch"
cp scripts/demo/BaselineBridgeTests.swift "$scratch/ios/dsh-mobileUITests/"
export DSHM_HOME="$scratch/host" DSHM_APPROVALS_COMMAND='echo compatibility-test'
mkdir "$DSHM_HOME"
(cd "$scratch/bridge" && corepack pnpm install --offline --frozen-lockfile && corepack pnpm build)
node "$scratch/scripts/demo/approvals-host.mjs" > "$scratch/host.log" 2>&1 &
pid=$!
for _ in {1..240}; do
  grep -q 'approvals-host: ready' "$scratch/host.log" && break
  kill -0 "$pid" || { tail -30 "$scratch/host.log"; exit 1; }
  sleep 0.5
done
grep -q 'approvals-host: ready' "$scratch/host.log"
export TEST_RUNNER_DSHM_COMPAT_PEER="$scratch/peer.json"
(cd "$scratch/bridge" && node --input-type=module <<'JS'
import { issue, redeem } from './lib/test/tls-client.js'
import { writeFileSync } from 'node:fs'
const state = process.env.DSHM_HOME + '/dsh-mobile-bridge'
const offer = await issue(state)
writeFileSync(process.env.TEST_RUNNER_DSHM_COMPAT_PEER + '.offer', offer.toString())
const { bearer } = await redeem(state, await issue(state))
const address = offer.searchParams.get('a').split(',')[0]
const pin = Buffer.from(offer.searchParams.get('k'), 'base64url').toString('base64')
writeFileSync(process.env.TEST_RUNNER_DSHM_COMPAT_PEER, JSON.stringify({ address, pin, bearer }))
JS
)
if xcrun simctl get_app_container "$DSHM_SIM" chang.dsh-mobile data >/dev/null 2>&1; then
  xcrun simctl uninstall "$DSHM_SIM" chang.dsh-mobile
fi
if xcrun simctl get_app_container "$DSHM_SIM" chang.dsh-mobile data >/dev/null 2>&1; then
  echo "previous app container still present" >&2; exit 1
fi
demo_tls_ui test -project "$scratch/ios/dsh-mobile.xcodeproj" -scheme dsh-mobile \
  -destination "platform=iOS Simulator,id=$DSHM_SIM" -derivedDataPath "$scratch/build" \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -parallel-testing-enabled NO \
  -only-testing:dsh-mobileUITests/BaselineBridgeTests --log "$scratch/test.log" || \
  { rg 'error:|failed|threw' "$scratch/test.log" | tail -20; exit 1; }
grep -E 'testApprovalAndQueueOverPinnedTLS.* passed' "$scratch/test.log"
(cd "$scratch/bridge" && node --input-type=module <<'JS'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { connectDevice } from './lib/test/tls-client.js'
const state = process.env.DSHM_HOME + '/dsh-mobile-bridge'
const { address, bearer } = JSON.parse(readFileSync(process.env.TEST_RUNNER_DSHM_COMPAT_PEER, 'utf8'))
for (const supported of [true, false]) {
  const caps = supported ? ['approvals.v1', 'conversation.v2'] : []
  const peer = await connectDevice(state, address, bearer, caps)
  try {
    const resumed = await peer.rpc({ case: 'resume', value: {} })
    assert.equal(resumed.case, 'resumed')
    const bodies = peer.events.map(f => f.kind.value.body.case)
    assert.equal(bodies[0], 'logReset')
    for (const family of ['queuedMessage', 'approvalPending', 'approvalResolved']) {
      assert.equal(bodies.includes(family), supported, family)
    }
    assert.ok(bodies.includes('taskUpserted'))
  } finally { peer.ws.close() }
}
console.log('Replay mapped approval and queue events for both capability sets')
JS
)
