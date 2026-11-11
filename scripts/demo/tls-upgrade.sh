#!/bin/bash
# Create a DSH conversation before the bridge is installed. Enroll a fresh phone on
# the same host profile, recover the old conversation and replay turns sent while offline.
set -euo pipefail
cd "$(dirname "$0")/../.."
export PATH="$HOME/.dshm/bin:$HOME/.nvm/versions/node/v24.14.0/bin:$PATH"
export DSHM_DD="${DSHM_DD:-/tmp/dshm-upgrade-${DSHM_SIM:-default}-dd}"
scripts/demo/session-visibility.sh --upgrade
scripts/pnpm-test --node-test lib/test/tls-upgrade.test.js
scripts/demo/reconnect.sh
