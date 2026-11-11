#!/bin/bash
# Create a DSH conversation before the bridge is installed. Enroll a fresh phone on
# the same host profile, recover the old conversation and replay turns sent while offline.
set -euo pipefail
cd "$(dirname "$0")/../.."
scripts/demo/session-visibility.sh --upgrade
scripts/pnpm-test --node-test lib/test/tls-upgrade.test.js
scripts/demo/reconnect.sh
