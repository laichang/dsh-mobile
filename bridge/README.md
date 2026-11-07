# dsh-mobile bridge

A [Cordis](https://github.com/cordiverse/cordis) plugin that runs inside your own DeepSeek Harness (DSH) host and lets the dsh-mobile iOS app talk to it. It opens its **own** WebSocket listener and speaks the protobuf protocol in [`../protocol/frame.proto`](../protocol/frame.proto). The app never talks to DSH's native API (ARCHITECTURE D4).

Status (S1): the listener (`0.0.0.0:47801` by default) is end-to-end encrypted with Noise (ARCHITECTURE D6, D21). A phone pairs once by scanning a QR the bridge prints, then reconnects with its own key. `CreateTask` creates a DSH session and streams its reply. The S7 composer can choose the host's default workspace, a recent workspace, or the absolute path of another existing directory on that host.

S2 adds `ListTasks` and `Resume` (capability `resume.v1`): tasks keep running when the app disconnects, and every event is numbered in a per-host log so the app can fetch exactly what it missed (ARCHITECTURE D20). The log is kept in memory; restarting DSH starts a new one.

S4 adds held approvals (`approvals.v1`). A paired phone or DSH web client can answer a request once. Set `approvalTimeoutMs` in the bridge plugin config to change the 24-hour default. The bridge rejects expired approvals and records decisions in `approvals.jsonl` in its state directory. Requests from other DSH sessions appear on the phone while they need a decision.


## Requirements

- DSH **0.2.2-rc.1** for task APIs. On another release the bridge serves only pairing and the version handshake. The app shows the installed and supported versions so you can update the bridge on that host.
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

   The plugin starts with the host and listens on `0.0.0.0:47801`. Check with `lsof -nP -iTCP:47801 -sTCP:LISTEN`. While no phone is paired yet, it prints a pairing QR in DSH's log.

4. Pair the phone. For a fresh QR at any time (single use, valid 10 minutes):

   ```sh
   DSH_HOME=~/.dsh node bridge/lib/scripts/pair.js
   ```

   In dsh-mobile, tap the QR button and scan it, then tap **Pair**. The QR lists every external IPv4 address of the host (Wi-Fi, Ethernet, Tailscale's `100.x`); the phone tries them in order, so it works on the same Wi-Fi or over Tailscale. The link printed under the QR can be pasted into the app instead.

5. Talk to it without the app (the CLI pairs like a phone):

   ```sh
   node bridge/lib/scripts/client.js --identity /tmp/cli-id.json --pair "$(DSH_HOME=~/.dsh node bridge/lib/scripts/pair.js --url-only)" "Say hello in one sentence."
   node bridge/lib/scripts/client.js --identity /tmp/cli-id.json "Again, reconnecting with the saved key."
   ```

   The reply streams to stdout. The command exits 0 when the task completes.

To remove it, run `dsh plugin --profile web remove @dsh-mobile/bridge`.

## Configuration

Defaults: `host: 0.0.0.0`, `port: 47801`, `cwd`: DSH's own default Workspace (`<Documents>/deepseek-harness/default-workspace`, shown as 默认工作区 in DSH Web), else your home directory (the default workspace for new tasks), `stateDir: $DSH_HOME/dsh-mobile-bridge`, `devPlaintext: false`. To change them, add an entry with id `dsh-mobile-bridge` to the profile's `cordis.yml`:

```yaml
- id: dsh-mobile-bridge
  config:
    port: 47811
    cwd: /Users/me/projects
```

The environment variables `DSHM_BRIDGE_HOST`, `DSHM_BRIDGE_PORT`, `DSHM_BRIDGE_STATE_DIR` and `DSHM_BRIDGE_DEV_PLAINTEXT=1` fill in whatever `cordis.yml` leaves out (`scripts/dsh-up.mjs` uses them).

**Pairing state** lives in `stateDir` (mode 0700, files 0600): `host-key.json` (the host's Noise private key; keep it private, deleting it unpairs every phone), `offers.json`, `devices.json` (the paired keys and pairing/revocation history), `approvals.jsonl` (approval decisions), and `listener.json` (the addresses `pair.js` puts in the QR).

On a paired phone, open **Devices and audit** under the host. The list marks the current phone and shows each device’s key fingerprint and connection dates. Revoking access disconnects that device and rejects its reconnect attempts until it pairs again. **Audit history** shows which device paired, revoked access, or answered an approval.

**Plaintext** (`devPlaintext: true`) is for development only: it serves unencrypted frames on the `/plaintext` path, and the bridge refuses to start with it unless `host` is a loopback literal (`127.x.x.x` or `::1`). Only Debug builds of the app have a plaintext channel.

## Local acceptance host (for development)

`node scripts/dsh-up.mjs` starts DSH 0.2.2-rc.1 from `~/.dshm/runtime` with `DSH_HOME=~/.dshm/home`, enables this bridge, and points DSH at DSH's mock LLM server, so no API key is needed. The script header lists its environment variables. Unlike the defaults above, it binds the bridge to `127.0.0.1` with `devPlaintext` on, so the Simulator can use both T0's plaintext path and Noise; for a real iPhone run it with `DSHM_BRIDGE_HOST=0.0.0.0 DSHM_BRIDGE_DEV_PLAINTEXT=0`. S1's demo is `scripts/demo/s1.sh`.

This is the development host on the maintainer's Mac:
- DSH is installed with npm (`@deepseek-ai/dsh@0.2.2-rc.1` and `@deepseek-ai/dsh-llm-mock-server@0.2.2-rc.1`) into `~/.dshm/runtime`.
- `~/.dshm/bin/pnpm` is a shim for `corepack pnpm@11.28.5`; put it on `PATH` for `dsh plugin`.
- The default `~/.dsh` is left untouched.
- S3's milestone demo uses `node scripts/demo/s3-host.mjs` instead: the same setup with `DSH_HOME=~/.dshm/home-s3`, web port 3285 and bridge port 47812 (written to the profile's `cordis.patch.yml`), and DSH's mock LLM scripted to keep a three-item todo list (ARCHITECTURE D19). `scripts/demo/s3.sh` runs it.
- Other worktrees use their own `DSH_HOME` and ports. For example, X1/X4 use `~/.dshm/home-x1x4`, web port 3282 and bridge ports 47803–47809.

## Development

| Command | What it does |
|---|---|
| `pnpm test` | Builds, then runs `node:test`: golden fixtures, Noise vectors and transcripts, bridge and pairing against `FakeDSH`, PlaintextChannel |
| `pnpm build` | `tsc` → `lib/` (what DSH loads) |
| `pnpm fixtures` | Writes `.binpb` files for new entries in `protocol/fixtures/fixtures.json` |
| `pnpm noise-fixtures` | Rewrites `protocol/fixtures/noise/transcripts.json` (golden Noise transcripts from fixed keys) |
| `../scripts/codegen` | Regenerates `src/gen/` (and the Swift side) from `protocol/*.proto` |

Layout:
- `src/dsh.ts` is the only file that knows DSH internals.
- `src/server.ts` is the listener and the frame protocol.
- `src/channel.ts` is the dev-only `PlaintextChannel`.
- `src/pairing/` is Noise (`noise.ts`, ported from the X2 spike), the wire header (`wire.ts`), the handshake (`handshake.ts`), offers and the QR (`offer.ts`, `announce.ts`) and the on-disk store (`store.ts`).
- `test/fake-dsh.ts` is `FakeDSH`.
