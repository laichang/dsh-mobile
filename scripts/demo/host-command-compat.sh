#!/bin/bash
# Run the current Swift command client against an isolated build of the baseline bridge.
set -euo pipefail
cd "$(dirname "$0")/../.."
export PATH="$HOME/.dshm/bin:$HOME/.nvm/versions/node/v24.14.0/bin:$PATH"
: "${DSHM_BRIDGE_PORT:?set the assigned bridge port}" "${DSHM_WEB_PORT:?set the assigned web port}"
umask 077
scratch=$(mktemp -d)
host_pid=''
cleanup() {
  if [[ -n "$host_pid" ]]; then kill "$host_pid" 2>/dev/null || true; wait "$host_pid" || true; fi
  rm -rf "$scratch"
}
trap cleanup EXIT
revision=61b54169a58e7a20e9ca243dc96a6739b816e14a
git archive "$revision" bridge scripts/dsh-up.mjs | tar -x -C "$scratch"
export DSHM_HOME="$scratch/home"
(cd "$scratch/bridge" && corepack pnpm install --offline --frozen-lockfile && corepack pnpm build)
for port in "$DSHM_BRIDGE_PORT" "$DSHM_WEB_PORT"; do
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null; then echo "Port $port is busy" >&2; exit 1; fi
done
node "$scratch/scripts/dsh-up.mjs" >"$scratch/host.log" 2>&1 &
host_pid=$!
for _ in {1..240}; do
  if lsof -nP -iTCP:"$DSHM_BRIDGE_PORT" -sTCP:LISTEN >/dev/null; then break; fi
  kill -0 "$host_pid" || { cat "$scratch/host.log"; exit 1; }
  sleep 0.5
done
export DSHM_COMMAND_FIXTURE="$scratch/client.json"
(cd "$scratch/bridge" && node --input-type=module <<'JS'
import { issue, redeem } from './lib/test/tls-client.js'
import { writeFileSync } from 'node:fs'
const state = process.env.DSHM_HOME + '/dsh-mobile-bridge'
const offer = await issue(state)
const { bearer } = await redeem(state, offer)
const address = offer.searchParams.get('a').split(',')[0]
const pin = Buffer.from(offer.searchParams.get('k'), 'base64url').toString('base64')
writeFileSync(process.env.DSHM_COMMAND_FIXTURE, JSON.stringify({ address, pin, bearer }))
JS
)
scripts/swift-test --filter HostCommandCompatibilityTests
echo "Swift Hello, Resume and ListTasks passed against bridge $revision"
