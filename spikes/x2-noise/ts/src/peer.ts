// Interop peer: runs one side of the interop script over stdin/stdout. Same CLI as the
// Swift noise-peer:
//   node src/peer.ts --role initiator|responder --protocol NAME --s HEX [--rs HEX] [--psk HEX]
//                    [--prologue HEX] [--pings N]
// On success prints "ok h=<hex> rs=<hex>" to stderr and exits 0; exits 1 on any failure.
import { parseArgs } from 'node:util';
import { keyPairFromSecret, hex, unhex } from './noise.ts';
import { StreamFrameIO, runInterop } from './interop.ts';

// Pipes are asynchronous on macOS: exit only once stderr has flushed.
const finish = (code: number, msg: string): never => {
  process.stderr.write(msg + '\n', () => process.exit(code));
  return undefined as never;
};
const fail = (msg: string): never => {
  throw new Error(msg);
};

try {
  const { values: o } = parseArgs({
    options: {
      role: { type: 'string' }, protocol: { type: 'string' }, s: { type: 'string' }, rs: { type: 'string' },
      psk: { type: 'string' }, prologue: { type: 'string' }, pings: { type: 'string' },
    },
  });
  if (o.role !== 'initiator' && o.role !== 'responder') fail('--role');
  if (!o.protocol) fail('--protocol');
  if (!o.s) fail('--s');
  const io = new StreamFrameIO(process.stdin, process.stdout);
  const r = await runInterop({
    initiator: o.role === 'initiator', protocolName: o.protocol!, s: keyPairFromSecret(unhex(o.s!)),
    rs: o.rs ? unhex(o.rs) : undefined, psk: o.psk ? unhex(o.psk) : undefined,
    prologue: o.prologue ? unhex(o.prologue) : undefined, pings: o.pings ? Number(o.pings) : undefined,
  }, io);
  finish(0, `ok h=${hex(r.handshakeHash)} rs=${hex(r.remoteStatic ?? new Uint8Array(0))}`);
} catch (e) {
  finish(1, `noise-peer(ts): ${e instanceof Error ? e.message : String(e)}`);
}
