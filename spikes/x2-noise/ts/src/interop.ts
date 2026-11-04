// The cross-language interop script; mirrors swift/Sources/NoiseKit/Interop.swift step for
// step (see the comment there for the frame format and the message sequence).
import type { Readable, Writable } from 'node:stream';
import { HandshakeState, MAX_MESSAGE_LENGTH, hex, type KeyPair } from './noise.ts';

export interface FrameIO {
  readFrame(): Promise<Uint8Array>;
  writeFrame(frame: Uint8Array): Promise<void>;
}

export interface InteropConfig {
  initiator: boolean;
  protocolName: string;
  s: KeyPair;
  rs?: Uint8Array;
  psk?: Uint8Array;
  prologue?: Uint8Array;
  pings?: number;
  impl?: string;
}

export interface InteropResult {
  handshakeHash: Uint8Array;
  remoteStatic: Uint8Array | undefined;
  peerImpl: string;
  received: string[];
}

const enc = new TextEncoder();
const dec = new TextDecoder();
export const DEFAULT_PROLOGUE = enc.encode('dshm/x2');

export async function runInterop(c: InteropConfig, io: FrameIO): Promise<InteropResult> {
  const impl = c.impl ?? 'ts';
  const pings = c.pings ?? 3;
  const hs = new HandshakeState({
    protocolName: c.protocolName, initiator: c.initiator, prologue: c.prologue ?? DEFAULT_PROLOGUE,
    s: c.s, rs: c.rs, psks: c.psk ? [c.psk] : [],
  });
  const received: string[] = [];
  let peerImpl = '';
  for (let i = 0; !hs.isComplete; i++) {
    if (hs.isMyTurn) {
      await io.writeFrame(hs.writeMessage(enc.encode(`hs${i} from ${impl}`)));
    } else {
      const text = dec.decode(hs.readMessage(await io.readFrame()));
      const prefix = `hs${i} from `;
      if (!text.startsWith(prefix)) throw new Error(`bad handshake payload: ${text}`);
      peerImpl = text.slice(prefix.length);
      received.push(text);
    }
  }
  const t = hs.transport!;
  const h = hex(hs.handshakeHash);
  const send = (s: string) => io.writeFrame(t.send.encrypt(enc.encode(s)));
  const expect = async (want: string) => {
    const got = dec.decode(t.receive.decrypt(await io.readFrame()));
    received.push(got);
    if (got !== want) throw new Error(`expected "${want}", got "${got}"`);
  };
  if (c.initiator) {
    for (let n = 0; n < pings; n++) {
      await send(`ping ${n}`);
      await expect(`pong ${n} ${peerImpl}`);
    }
    await send(`bye ${h}`);
    await expect(`bye ${h}`);
  } else {
    for (let n = 0; n < pings; n++) {
      await expect(`ping ${n}`);
      await send(`pong ${n} ${impl}`);
    }
    await expect(`bye ${h}`);
    await send(`bye ${h}`);
  }
  return { handshakeHash: hs.handshakeHash, remoteStatic: hs.remoteStatic, peerImpl, received };
}

/** Length-prefixed frames (2-byte big-endian length) over a pair of streams. */
export class StreamFrameIO implements FrameIO {
  private buf = new Uint8Array(0);
  private ended = false;
  private wake: (() => void) | undefined;
  private readonly output: Writable;

  constructor(input: Readable, output: Writable) {
    this.output = output;
    input.on('data', (chunk: Buffer) => {
      const next = new Uint8Array(this.buf.length + chunk.length);
      next.set(this.buf);
      next.set(chunk, this.buf.length);
      this.buf = next;
      this.wake?.();
    });
    input.on('end', () => {
      this.ended = true;
      this.wake?.();
    });
  }

  private async readExactly(n: number): Promise<Uint8Array> {
    while (this.buf.length < n) {
      if (this.ended) throw new Error('peer closed the stream');
      await new Promise<void>((r) => (this.wake = r));
      this.wake = undefined;
    }
    const out = this.buf.slice(0, n);
    this.buf = this.buf.slice(n);
    return out;
  }

  async readFrame(): Promise<Uint8Array> {
    const len = await this.readExactly(2);
    return this.readExactly((len[0] << 8) | len[1]);
  }

  writeFrame(frame: Uint8Array): Promise<void> {
    if (frame.length > MAX_MESSAGE_LENGTH) throw new Error('frame too long');
    const out = new Uint8Array(2 + frame.length);
    out[0] = frame.length >> 8;
    out[1] = frame.length & 0xff;
    out.set(frame, 2);
    return new Promise((resolve, reject) => this.output.write(out, (err) => (err ? reject(err) : resolve())));
  }
}
