# dsh-mobile bridge

A [Cordis](https://github.com/cordiverse/cordis) plugin that runs inside your own DeepSeek Harness (DSH) host and lets the dsh-mobile iOS app talk to it. It opens its **own** WebSocket listener and speaks the protobuf protocol in [`../protocol/frame.proto`](../protocol/frame.proto). The app never talks to DSH's native API (ARCHITECTURE D4).

T0 status: plaintext on loopback only (`127.0.0.1:47801`), one request (`CreateTask`): it creates a DSH session in a fixed workspace, prompts it with DSH's default model, and streams the assistant text back. Pairing and encryption come in S1.

S2 adds `ListTasks` and `Resume` (capability `resume.v1`): tasks keep running when the app disconnects, and every event is numbered in a per-host log so the app can fetch exactly what it missed (ARCHITECTURE D20). The log is kept in memory; restarting DSH starts a new one.

## Requirements

- DSH **≥ 0.2.2-rc.1** (enforced by `engines.dsh`).
- Node **≥ 24.9** (DSH's own requirement).
- **pnpm** on `PATH`. `dsh plugin` runs `pnpm add` in the profile. The bridge pins pnpm 11.28.5 through `packageManager`, so `corepack pnpm` works.

## Install and enable in a DSH profile

1. Build the bridge:

   ```sh
   cd bridge
   pnpm install
   pnpm build
   ```

2. Add it to the profile you run (here `web`). This links the directory into `$DSH_HOME/profiles/web` and appends `@dsh-mobile/bridge` to the profile's bundles:

   ```sh
   DSH_HOME=~/.dsh dsh plugin --profile web add /path/to/dsh-mobile/bridge
   ```

   Leave out `DSH_HOME` to use the default (`~/.dsh`).

3. Start (or restart) DSH:

   ```sh
   dsh web
   ```

   The plugin starts with the host and listens on `127.0.0.1:47801`. Check with `lsof -nP -iTCP:47801 -sTCP:LISTEN`.

4. Talk to it without the app:

   ```sh
   node bridge/lib/scripts/client.js "Say hello in one sentence."
   ```

   The reply streams to stdout. The command exits 0 when the task completes.

To remove it, run `dsh plugin --profile web remove @dsh-mobile/bridge`.

## Configuration

Defaults: `host: 127.0.0.1`, `port: 47801`, `cwd`: your home directory, used as the workspace for new tasks. To change them, add an entry with id `dsh-mobile-bridge` to the profile's `cordis.yml`:

```yaml
- id: dsh-mobile-bridge
  config:
    port: 47811
    cwd: /Users/me/projects
```

`host` must be a loopback literal (`127.x.x.x` or `::1`) while the bridge only has the plaintext channel. Any other address is refused at startup.

## Local acceptance host (for development)

`node scripts/dsh-up.mjs` starts DSH 0.2.2-rc.1 from `~/.dshm/runtime` with `DSH_HOME=~/.dshm/home`, enables this bridge, and points DSH at DSH's mock LLM server, so no API key is needed. The script header lists its environment variables.

This is the development host on the maintainer's Mac:
- DSH is installed with npm (`@deepseek-ai/dsh@0.2.2-rc.1` and `@deepseek-ai/dsh-llm-mock-server@0.2.2-rc.1`) into `~/.dshm/runtime`.
- `~/.dshm/bin/pnpm` is a shim for `corepack pnpm@11.28.5`; put it on `PATH` for `dsh plugin`.
- The default `~/.dsh` is left untouched.
- S3's milestone demo uses `node scripts/demo/s3-host.mjs` instead: the same setup with `DSH_HOME=~/.dshm/home-s3`, web port 3285 and bridge port 47812 (written to the profile's `cordis.patch.yml`), and DSH's mock LLM scripted to keep a three-item todo list (ARCHITECTURE D19). `scripts/demo/s3.sh` runs it.
- Other worktrees use their own `DSH_HOME` and ports. For example, X1/X4 use `~/.dshm/home-x1x4`, web port 3282 and bridge ports 47803–47809.

## Development

| Command | What it does |
|---|---|
| `pnpm test` | Builds, then runs `node:test`: golden fixtures, bridge against `FakeDSH`, PlaintextChannel |
| `pnpm build` | `tsc` → `lib/` (what DSH loads) |
| `pnpm fixtures` | Writes `.binpb` files for new entries in `protocol/fixtures/fixtures.json` |
| `../scripts/codegen` | Regenerates `src/gen/` (and the Swift side) from `protocol/*.proto` |

Layout:
- `src/dsh.ts` is the only file that knows DSH internals.
- `src/server.ts` is the listener and the frame protocol.
- `src/channel.ts` is the `SecureChannel` seam.
- `test/fake-dsh.ts` is `FakeDSH`.
