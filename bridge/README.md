# dsh-mobile bridge

A [Cordis](https://github.com/cordiverse/cordis) plugin that runs inside your own DeepSeek Harness (DSH) host and lets the dsh-mobile iOS app talk to it. It opens its **own** WebSocket listener and speaks the protobuf protocol in [`../protocol/frame.proto`](../protocol/frame.proto). The app never talks to DSH's native API: upstream changes are absorbed here (ARCHITECTURE.md §4).

The listener (`0.0.0.0:47801` by default) is a TLS 1.3 WebSocket server. The pairing CLI shows a QR that pins the host’s identity. Each enrolled phone reconnects with its own credential. The bridge creates DSH sessions and streams them, maps milestones and transcript rows, holds approvals and agent questions, takes follow-up messages and attachments, and lists models, workspaces, devices and the audit log.

Tasks keep running when the app disconnects. Every event is numbered in a per-host log, so the app fetches exactly what it missed (`Resume`). The log is kept in memory; restarting DSH starts a new one.

Held approvals: a paired phone or a DSH web client answers a request once. Set `approvalTimeoutMs` in the bridge plugin config to change the 24-hour default. The bridge rejects expired approvals and records decisions in `approvals.jsonl` in its state directory. Requests from other DSH sessions appear on the phone while they need a decision.


## Requirements

- DSH **0.2.2-rc.1** for task APIs. On another release the bridge serves only pairing and the version handshake. The app shows the installed and supported versions so you can update the bridge on that host.
- An OpenSSL-compatible executable on the host’s `PATH` for certificate issuance and renewal. Certificate signing and private Unix socket access have been verified on macOS with LibreSSL and OpenSSL. Linux remains unverified. Windows enrollment requires an owner-restricted IPC implementation.
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

   The plugin starts with the host and listens on `0.0.0.0:47801`. Check with `lsof -nP -iTCP:47801 -sTCP:LISTEN`.

4. Pair the phone. For a fresh QR at any time, run this from the dsh-mobile repository root (single use, valid 10 minutes):

   ```sh
   node bridge/lib/scripts/pair.js
   ```

   By default, DSH stores its settings and data in `~/.dsh`. The pairing command uses this folder automatically. If you chose a different folder when starting DSH, set the same folder in the terminal that generates the code. For example, if you started DSH with `DSH_HOME=/work/dsh dsh web`, run `DSH_HOME=/work/dsh node bridge/lib/scripts/pair.js`. If the plugin uses a custom `stateDir`, append `--state-dir /path/to/stateDir`.

   In dsh-mobile, tap the QR button and scan it, then tap **Pair**. The QR lists every external IPv4 address of the host (Wi-Fi, Ethernet, Tailscale's `100.x`); the phone tries them in order, so it works on the same Wi-Fi, or over Tailscale when Tailscale is on at both the phone and the host. The link printed under the QR can be pasted into the app instead.

### Update an existing installation

1. Keep the current DSH profile, workspace directory and bridge `stateDir`. Rebuild the plugin and its pairing CLI from the same checkout. Restart DSH with that profile.
2. Install the matching iOS app, run the updated `pair.js` on the host, and scan its fresh QR. The phone returns to the welcome screen with a legacy pairing. The old QR, host key and device record cannot authorize this release.
3. Open a previous conversation from the drawer. Sessions and transcripts remain on the host. Devices and audit includes historical pairing, revocation and approval entries.
4. Preserve `stateDir/tls/host-key.pem` across renewals. If the key changes, check that this is the intended computer and enroll again using a QR generated on it.

To remove it, run `dsh plugin --profile web remove @dsh-mobile/bridge`.

## Configuration

Defaults: `host: 0.0.0.0`, `port: 47801`, `cwd`: DSH's own default Workspace (`<Documents>/deepseek-harness/default-workspace`, shown as 默认工作区 in DSH Web), else your home directory (the default workspace for new tasks), `stateDir: $DSH_HOME/dsh-mobile-bridge`. To change them, add an entry with id `dsh-mobile-bridge` to the profile's `cordis.yml`:

```yaml
- id: dsh-mobile-bridge
  config:
    port: 47811
    cwd: /Users/me/projects
```

The environment variables `DSHM_BRIDGE_HOST`, `DSHM_BRIDGE_PORT` and `DSHM_BRIDGE_STATE_DIR` fill in whatever `cordis.yml` leaves out (`scripts/dsh-up.mjs` uses them).

**When the bridge cannot listen** (another program holds the port, no permission for it, or `host` is not an address of this computer), the terminal where DSH runs shows one line (on stderr, also sent to DSH's logger) that names the address, the cause and the fix, for example `dsh-mobile-bridge cannot listen on 0.0.0.0:47801: another program uses port 47801 (EADDRINUSE). … Fix: stop that program (lsof -nP -iTCP:47801 -sTCP:LISTEN shows it), or change port … to a free port, restart DSH and pair the phone again.` DSH keeps running without the bridge. The phone shows the host offline with the reason: another program uses the port, or nothing listens on it. The bridge does not move to another port by itself: the phone saved the port when it paired, so after a port change, pair it again.

**Pairing state** lives under `stateDir`. TLS uses its own key, certificate and device registry in `tls/`. Active bearer credentials are stored as digests on the host. Old device records supply historical audit entries. Approval decisions remain in `approvals.jsonl`.

On a paired phone, open **Devices and audit** for this host to see its device IDs, recent activity and paginated history. Revoking a device closes its current sockets and prevents reconnects.

## Local acceptance host (for development)

`node scripts/dsh-up.mjs` starts DSH 0.2.2-rc.1 from `~/.dshm/runtime` with `DSH_HOME=~/.dshm/home`, enables this bridge, and points DSH at DSH's mock LLM server, so no API key is needed. The script header lists its environment variables. Unlike the defaults above, it binds TLS to `127.0.0.1` for the simulator. For a real iPhone run it with `DSHM_BRIDGE_HOST=0.0.0.0`. The pairing demo is `scripts/demo/pairing.sh`.

This is the development host on the maintainer's Mac:
- DSH is installed with npm (`@deepseek-ai/dsh@0.2.2-rc.1` and `@deepseek-ai/dsh-llm-mock-server@0.2.2-rc.1`) into `~/.dshm/runtime`.
- `~/.dshm/bin/pnpm` is a shim for `corepack pnpm@11.28.5`; put it on `PATH` for `dsh plugin`.
- The default `~/.dsh` is left untouched.
- The milestone demo uses `node scripts/demo/milestones-host.mjs` instead: the same setup with `DSH_HOME=~/.dshm/home-s3`, web port 3285 and bridge port 47812 (written to the profile's `cordis.patch.yml`), and DSH's mock LLM scripted to keep a three-item todo list. `scripts/demo/milestones.sh` runs it.
- Other worktrees use their own `DSH_HOME` and ports. For example, X1/X4 use `~/.dshm/home-x1x4`, web port 3282 and bridge ports 47803–47809.

## Development

| Command | What it does |
|---|---|
| `pnpm test` | Builds, then runs `node:test`: golden fixtures, TLS enrollment, upgrade, bridge and pairing against `FakeDSH` |
| `pnpm build` | `tsc` → `lib/` (what DSH loads) |
| `pnpm fixtures` | Writes `.binpb` files for new entries in `protocol/fixtures/fixtures.json` |
| `../scripts/codegen` | Regenerates `src/gen/` (and the Swift side) from `protocol/*.proto` |

Layout:
- `src/dsh.ts` is the only file that knows DSH internals.
- `src/server.ts` is the listener and the frame protocol.
- `src/pairing/` handles advertised addresses and QR parsing. `src/tls/` owns certificates, local offers, the listener and the credential registry.
- `test/fake-dsh.ts` is `FakeDSH`.


### Certificate and address changes

The TLS identity helper stores one P-256 PKCS#8 key under an owner-only directory. It invokes the host's OpenSSL-compatible CLI to sign a 90-day self-signed leaf. On startup or an address change, call the helper with the advertised hosts and load the returned key and certificate into the HTTPS listener. It renews within seven days of expiry or when a required SAN is missing. Renewal preserves the key and its SHA-256 DER SubjectPublicKeyInfo pin. Signing was verified on macOS with the system LibreSSL executable and OpenSSL. Linux and Windows provisioning have yet to be verified.

The TLS enrollment QR needs the pin and the same addresses used for the certificate. For a wildcard bind the existing listener announcement enumerates LAN and VPN IP addresses. A specific bind advertises its configured IP or DNS name. Include each advertised IP as an IP SAN and each DNS name as a DNS SAN. A DNS address can resolve to a new IP under the same certificate. To advertise a new literal IP, renew the certificate under the same key. The phone retries the saved addresses and promotes the one that succeeds. If every address fails, the hosts sheet shows each error and offers a new pairing.

`scripts/demo/pinned-tls.sh` exercises the production Swift transport under strict ATS on an iOS simulator.


### TLS device enrollment

Run `node bridge/lib/scripts/pair.js` in the same profile to display a version 2 QR. The bridge mints the offer over a Unix socket in an owner-only directory, with mode 0600 on the socket. Only the CLI displays the link. Each offer expires after ten minutes by default and can be redeemed once. Restarting the listener invalidates outstanding offers. If enrollment is interrupted, request a fresh QR.

The phone posts the offer to `/enroll` over pinned HTTPS. It stores the returned bearer in a ThisDeviceOnly Keychain item per device. Each reconnect checks `/device` and sends its bearer in the WebSocket upgrade. Only an explicit device refusal from the pinned host removes the pairing. The bridge stores bearer digests and device history under `tls/devices.json`; revoked devices lose all their sockets. The host key and device registry survive restarts. Unix socket access control and certificate provisioning have been exercised on macOS. Linux remains unverified. Windows enrollment needs an owner-restricted IPC implementation.
