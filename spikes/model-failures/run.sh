#!/bin/sh
# X1 (M2): run one task against real DSH 0.2.2-rc.1 for each model failure (fake DeepSeek
# provider) and record what DSH sends. See README.md and the header of run.mjs.
# Needs: ~/.dshm/runtime (DSH + mock server), Node >= 24.9, a pnpm on PATH (`dsh plugin add`).
# Writes fixtures/<case>.json and results/latest.json; exits non-zero if a case fails to record.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
if ! node -e 'process.exit(+process.versions.node.split(".")[0] >= 24 ? 0 : 1)' 2>/dev/null; then
  for d in "$HOME"/.nvm/versions/node/v24*/bin; do PATH="$d:$PATH"; done
fi
PATH="$HOME/.dshm/bin:$PATH"
export PATH
exec node "$here/run.mjs" "$@"
