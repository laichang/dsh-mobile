#!/bin/bash
# Check the live-demo inventory, including fixtures behind relays and upstream probes.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 - <<'PY'
from pathlib import Path
import re

root = Path('scripts/demo')
demos = set('approvals attachments bridge-errors devices drawer durable-list first-run first-run-release followup interrupt milestones model-failures models multi-host pair-again pair-tailscale pairing questions reconnect revoke rich-detail round-trip session-visibility ui-health upstream-version workspaces'.split())
special = {'pinned-tls', 'tls-enrollment', 'tls-upgrade'}
bad = []
def code(path):
    return '\n'.join(line for line in path.read_text().splitlines() if not line.lstrip().startswith(('#', '//')))
def require(path, condition, reason):
    if not condition:
        bad.append(f'{path}: {reason}')

legacy = re.compile(r'ws://|DSHM_BRIDGE_DEV_PLAINTEXT\s*[:=]\s*["\x27]?1|devPlaintext\s*:\s*true|lib/scripts/client\.js|\+\s*PLAINTEXT_PATH|new NoiseInitiator')
def check(path, source):
    require(path, not legacy.search(source), 'uses a legacy live transport')

for file in root.glob('*.sh'):
    if file.name == 'check-tls-demos.sh':
        continue
    source = code(file)
    if re.search(r'(?:node\s+\S*(?:dsh-up|[-]host)\.mjs|node\s+\S*pair\.js|dsh web)', source):
        require(file, file.stem in demos | special or file.stem == 'lib', 'add the listener to the demo inventory')
for name in sorted(demos):
    file = root / (name + '.sh')
    source = code(file)
    require(file, 'demo_tls_home' in source and 'demo_tls_ui' in source, 'use shared TLS enrollment')
    check(file, source)
for file in [*root.glob('*-host.mjs'), Path('scripts/dsh-up.mjs'), Path('scripts/ci/bridge-upstream'), Path('bridge/scripts/probe-upstream.ts')]:
    check(file, code(file))
for file in Path('bridge/test').glob('*.test.ts'):
    source = code(file)
    check(file, source)
    if 'startBridgeServer(' in source:
        require(file, 'tlsStateDir' in source, 'use a TLS listener or startTestBridge')
if bad:
    raise SystemExit('\n'.join(bad))
print(f'{len(demos)} live UI demos use shared TLS enrollment. Host fixtures and upstream probes checked.')
PY

# A standalone demo removes only the home it created, on both success and failure.
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
base="$scratch/original profile"
mkdir -p "$base"
touch "$base/keep"
for status in 0 17; do
  result=0
  DSHM_HOME="$base" bash -s -- "$scratch" "$status" <<'BASH' || result=$?
    set -eu
    unset SIM DSHM_SIM
    source scripts/demo/lib.sh
    diagnostic="$1/diagnostic"
    sleep 60 &
    host=$!
    cleanup() {
      kill "$host"
      wait "$host" || [[ $? == 143 ]] || return 1
      [[ -f "$demo_tls_profile/host-key" ]] || return 1
      touch "$diagnostic"
    }
    if [[ $2 == 0 ]]; then trap cleanup EXIT; fi
    demo_tls_home
    printf "%s" "$DSHM_HOME" > "$1/profile"
    touch "$DSHM_HOME/host-key" "$DSHM_HOME/device-bearer"
    if [[ $2 != 0 ]]; then demo_tls_on_exit cleanup; fi
    DSHM_HOME="$1"
    exit "$2"
BASH
  [[ $result == "$status" && ! -e "$(cat "$scratch/profile")" && -f "$base/keep" && -f "$scratch/diagnostic" ]]
  rm "$scratch/diagnostic"
done
echo 'Disposable profiles removed after successful and failed demos.'
