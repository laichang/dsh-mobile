// Noise Protocol Framework (rev 34) on @noble/*: DH 25519, ChaChaPoly or AESGCM, SHA256.
// Mirrors swift/Sources/NoiseKit/Noise.swift. X2 spike code: correct against the official
// vectors, but not hardened or reviewed.
import { x25519 } from '@noble/curves/ed25519.js';
import { chacha20poly1305 } from '@noble/ciphers/chacha.js';
import { gcm } from '@noble/ciphers/aes.js';
import { sha256 } from '@noble/hashes/sha2.js';
import { hmac } from '@noble/hashes/hmac.js';

export const MAX_MESSAGE_LENGTH = 65535;
const DHLEN = 32;
const HASHLEN = 32;
const TAGLEN = 16;
const MAX_NONCE = 2n ** 64n - 1n;

export class NoiseError extends Error {}
export class DecryptError extends NoiseError {
  constructor() {
    super('decrypt failed');
  }
}

export type Cipher = 'ChaChaPoly' | 'AESGCM';
export type Token = 'e' | 's' | 'ee' | 'es' | 'se' | 'ss' | 'psk';

export interface HandshakePattern {
  name: string;
  initiatorPre: Token[];
  responderPre: Token[];
  messages: Token[][];
}

const BASE: Record<string, [Token[], Token[], Token[][]]> = {
  NN: [[], [], [['e'], ['e', 'ee']]],
  NK: [[], ['s'], [['e', 'es'], ['e', 'ee']]],
  XX: [[], [], [['e'], ['e', 'ee', 's', 'es'], ['s', 'se']]],
  IK: [[], ['s'], [['e', 'es', 's', 'ss'], ['e', 'ee', 'se']]],
  IX: [[], [], [['e', 's'], ['e', 'ee', 'se', 's', 'es']]],
  KK: [['s'], ['s'], [['e', 'es', 'ss'], ['e', 'ee', 'se']]],
};

/** Parses e.g. "IK", "IKpsk2", "XXpsk0+psk3". */
export function parsePattern(name: string): HandshakePattern {
  const baseName = /^[A-Z]+/.exec(name)?.[0] ?? '';
  const b = BASE[baseName];
  if (!b) throw new NoiseError(`unsupported pattern ${name}`);
  const messages = b[2].map((m) => [...m]);
  const mods = name.slice(baseName.length);
  if (mods) {
    for (const mod of mods.split('+')) {
      const m = /^psk(\d+)$/.exec(mod);
      const n = m ? Number(m[1]) : NaN;
      if (!(n >= 0 && n <= messages.length)) throw new NoiseError(`unsupported pattern ${name}`);
      if (n === 0) messages[0].unshift('psk');
      else messages[n - 1].push('psk');
    }
  }
  return { name, initiatorPre: b[0], responderPre: b[1], messages };
}

export function parseProtocol(name: string): { pattern: HandshakePattern; cipher: Cipher } {
  const p = name.split('_');
  if (p.length !== 5 || p[0] !== 'Noise' || p[2] !== '25519' || p[4] !== 'SHA256' ||
      (p[3] !== 'ChaChaPoly' && p[3] !== 'AESGCM')) {
    throw new NoiseError(`unsupported protocol ${name}`);
  }
  return { pattern: parsePattern(p[1]), cipher: p[3] };
}

// MARK: primitives

const concat = (...a: Uint8Array[]): Uint8Array => {
  const out = new Uint8Array(a.reduce((n, x) => n + x.length, 0));
  let o = 0;
  for (const x of a) {
    out.set(x, o);
    o += x.length;
  }
  return out;
};

/** Noise's HKDF (spec §4.3). */
export function hkdf(ck: Uint8Array, ikm: Uint8Array, outputs: 2 | 3): Uint8Array[] {
  const temp = hmac(sha256, ck, ikm);
  const out: Uint8Array[] = [];
  let prev = new Uint8Array(0);
  for (let i = 1; i <= outputs; i++) {
    prev = hmac(sha256, temp, concat(prev, Uint8Array.of(i)));
    out.push(prev);
  }
  return out;
}

export interface KeyPair {
  secretKey: Uint8Array;
  publicKey: Uint8Array;
}

export const generateKeyPair = (): KeyPair => x25519.keygen();
export const keyPairFromSecret = (secretKey: Uint8Array): KeyPair => ({
  secretKey,
  publicKey: x25519.getPublicKey(secretKey),
});

function dh(kp: KeyPair, pub: Uint8Array): Uint8Array {
  try {
    return x25519.getSharedSecret(kp.secretKey, pub);
  } catch {
    throw new NoiseError('DH failed');
  }
}

// MARK: CipherState (spec §5.1)

export class CipherState {
  readonly cipher: Cipher;
  private key: Uint8Array | undefined;
  nonce = 0n;

  constructor(cipher: Cipher, key?: Uint8Array) {
    this.cipher = cipher;
    this.key = key;
  }

  get hasKey(): boolean {
    return this.key !== undefined;
  }

  initializeKey(k: Uint8Array | undefined): void {
    this.key = k;
    this.nonce = 0n;
  }

  /** 32 zero bits, then the 64-bit counter: little-endian for ChaChaPoly, big-endian for AESGCM. */
  private nonceBytes(n: bigint): Uint8Array {
    const out = new Uint8Array(12);
    new DataView(out.buffer).setBigUint64(4, n, this.cipher === 'ChaChaPoly');
    return out;
  }

  private aead(key: Uint8Array, n: bigint, ad: Uint8Array) {
    const nonce = this.nonceBytes(n);
    return this.cipher === 'ChaChaPoly' ? chacha20poly1305(key, nonce, ad) : gcm(key, nonce, ad);
  }

  encrypt(plaintext: Uint8Array, ad: Uint8Array = new Uint8Array(0)): Uint8Array {
    if (!this.key) return plaintext;
    if (this.nonce === MAX_NONCE) throw new NoiseError('nonce exhausted');
    const ct = this.aead(this.key, this.nonce, ad).encrypt(plaintext);
    this.nonce++;
    return ct;
  }

  decrypt(ciphertext: Uint8Array, ad: Uint8Array = new Uint8Array(0)): Uint8Array {
    if (!this.key) return ciphertext;
    if (this.nonce === MAX_NONCE) throw new NoiseError('nonce exhausted');
    if (ciphertext.length < TAGLEN) throw new NoiseError('message too short');
    let pt: Uint8Array;
    try {
      pt = this.aead(this.key, this.nonce, ad).decrypt(ciphertext);
    } catch {
      throw new DecryptError();
    }
    this.nonce++;
    return pt;
  }

  /** REKEY (spec §4.2). */
  rekey(): void {
    if (!this.key) return;
    this.key = this.aead(this.key, MAX_NONCE, new Uint8Array(0)).encrypt(new Uint8Array(32)).slice(0, 32);
  }
}

// MARK: SymmetricState (spec §5.2)

class SymmetricState {
  cs: CipherState;
  ck: Uint8Array;
  h: Uint8Array;

  constructor(protocolName: string, cipher: Cipher) {
    const name = new TextEncoder().encode(protocolName);
    this.h = name.length <= HASHLEN ? concat(name, new Uint8Array(HASHLEN - name.length)) : sha256(name);
    this.ck = this.h;
    this.cs = new CipherState(cipher);
  }

  mixKey(ikm: Uint8Array): void {
    const [ck, k] = hkdf(this.ck, ikm, 2);
    this.ck = ck;
    this.cs.initializeKey(k);
  }

  mixHash(data: Uint8Array): void {
    this.h = sha256(concat(this.h, data));
  }

  mixKeyAndHash(ikm: Uint8Array): void {
    const [ck, th, k] = hkdf(this.ck, ikm, 3);
    this.ck = ck;
    this.mixHash(th);
    this.cs.initializeKey(k);
  }

  encryptAndHash(pt: Uint8Array): Uint8Array {
    const ct = this.cs.encrypt(pt, this.h);
    this.mixHash(ct);
    return ct;
  }

  decryptAndHash(ct: Uint8Array): Uint8Array {
    const pt = this.cs.decrypt(ct, this.h);
    this.mixHash(ct);
    return pt;
  }

  split(): [CipherState, CipherState] {
    const [k1, k2] = hkdf(this.ck, new Uint8Array(0), 2);
    return [new CipherState(this.cs.cipher, k1), new CipherState(this.cs.cipher, k2)];
  }
}

// MARK: HandshakeState (spec §5.3)

export interface Transport {
  send: CipherState;
  receive: CipherState;
}

export interface HandshakeOptions {
  protocolName: string;
  initiator: boolean;
  prologue?: Uint8Array;
  s?: KeyPair;
  /** Test vectors only; in production leave it unset and a fresh one is generated. */
  e?: KeyPair;
  rs?: Uint8Array;
  psks?: Uint8Array[];
}

export class HandshakeState {
  readonly initiator: boolean;
  private readonly pattern: HandshakePattern;
  private readonly ss: SymmetricState;
  readonly s: KeyPair | undefined;
  private e: KeyPair | undefined;
  remoteStatic: Uint8Array | undefined;
  private re: Uint8Array | undefined;
  private readonly psks: Uint8Array[];
  private readonly pskMode: boolean;
  private messageIndex = 0;
  transport: Transport | undefined;

  constructor(o: HandshakeOptions) {
    const { pattern, cipher } = parseProtocol(o.protocolName);
    const pskCount = pattern.messages.flat().filter((t) => t === 'psk').length;
    const psks = o.psks ?? [];
    if (psks.length !== pskCount) throw new NoiseError(`expected ${pskCount} psks, got ${psks.length}`);
    if (psks.some((p) => p.length !== 32)) throw new NoiseError('psk must be 32 bytes');
    if (o.rs && o.rs.length !== DHLEN) throw new NoiseError('bad remote static');
    this.initiator = o.initiator;
    this.pattern = pattern;
    this.ss = new SymmetricState(o.protocolName, cipher);
    this.s = o.s;
    this.e = o.e;
    this.remoteStatic = o.rs;
    this.psks = [...psks];
    this.pskMode = pskCount > 0;
    this.ss.mixHash(o.prologue ?? new Uint8Array(0));
    // Pre-messages: only "s" occurs in the supported patterns.
    for (const [tokens, mine] of [[pattern.initiatorPre, o.initiator], [pattern.responderPre, !o.initiator]] as const) {
      for (const t of tokens) {
        if (t !== 's') continue;
        const key = mine ? this.s?.publicKey : this.remoteStatic;
        if (!key) throw new NoiseError(mine ? 'missing local static' : 'missing remote static');
        this.ss.mixHash(key);
      }
    }
  }

  get isComplete(): boolean {
    return this.transport !== undefined;
  }

  get isMyTurn(): boolean {
    return !this.isComplete && (this.messageIndex % 2 === 0) === this.initiator;
  }

  get handshakeHash(): Uint8Array {
    return this.ss.h;
  }

  private need<T>(v: T | undefined, what: string): T {
    if (v === undefined) throw new NoiseError(`missing ${what}`);
    return v;
  }

  private mixDH(t: Token): void {
    const e = () => this.need(this.e, 'e');
    const s = () => this.need(this.s, 's');
    const re = () => this.need(this.re, 're');
    const rs = () => this.need(this.remoteStatic, 'rs');
    switch (t) {
      case 'ee': return this.ss.mixKey(dh(e(), re()));
      case 'ss': return this.ss.mixKey(dh(s(), rs()));
      case 'es': return this.ss.mixKey(this.initiator ? dh(e(), rs()) : dh(s(), re()));
      case 'se': return this.ss.mixKey(this.initiator ? dh(s(), re()) : dh(e(), rs()));
      case 'psk': return this.ss.mixKeyAndHash(this.need(this.psks.shift(), 'psk'));
      default: throw new Error('unreachable');
    }
  }

  writeMessage(payload: Uint8Array = new Uint8Array(0)): Uint8Array {
    if (this.isComplete) throw new NoiseError('handshake complete');
    if (!this.isMyTurn) throw new NoiseError('not my turn');
    const out: Uint8Array[] = [];
    for (const t of this.pattern.messages[this.messageIndex]) {
      if (t === 'e') {
        this.e ??= generateKeyPair();
        out.push(this.e.publicKey);
        this.ss.mixHash(this.e.publicKey);
        if (this.pskMode) this.ss.mixKey(this.e.publicKey);
      } else if (t === 's') {
        out.push(this.ss.encryptAndHash(this.need(this.s, 'local static').publicKey));
      } else {
        this.mixDH(t);
      }
    }
    out.push(this.ss.encryptAndHash(payload));
    const msg = concat(...out);
    if (msg.length > MAX_MESSAGE_LENGTH) throw new NoiseError('message too long');
    this.advance();
    return msg;
  }

  readMessage(message: Uint8Array): Uint8Array {
    if (this.isComplete) throw new NoiseError('handshake complete');
    if (this.isMyTurn) throw new NoiseError('not my turn');
    if (message.length > MAX_MESSAGE_LENGTH) throw new NoiseError('message too long');
    let off = 0;
    const take = (n: number): Uint8Array => {
      if (message.length - off < n) throw new NoiseError('message too short');
      off += n;
      return message.subarray(off - n, off);
    };
    for (const t of this.pattern.messages[this.messageIndex]) {
      if (t === 'e') {
        this.re = take(DHLEN).slice();
        this.ss.mixHash(this.re);
        if (this.pskMode) this.ss.mixKey(this.re);
      } else if (t === 's') {
        this.remoteStatic = this.ss.decryptAndHash(take(this.ss.cs.hasKey ? DHLEN + TAGLEN : DHLEN));
      } else {
        this.mixDH(t);
      }
    }
    const payload = this.ss.decryptAndHash(message.subarray(off));
    this.advance();
    return payload;
  }

  private advance(): void {
    this.messageIndex++;
    if (this.messageIndex === this.pattern.messages.length) {
      const [c1, c2] = this.ss.split();
      this.transport = this.initiator ? { send: c1, receive: c2 } : { send: c2, receive: c1 };
    }
  }
}

export const hex = (b: Uint8Array): string => Buffer.from(b).toString('hex');
export const unhex = (s: string): Uint8Array => {
  if (!/^([0-9a-fA-F]{2})*$/.test(s)) throw new NoiseError(`not hex: ${s}`);
  return new Uint8Array(Buffer.from(s, 'hex'));
};
