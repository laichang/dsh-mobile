# X2 · Spike: Noise interop: conclusion

Working note for PLAN.md X2 (answers ARCHITECTURE §8.3, feeds D6 and S1). Archive it to `.archive/YYYYMMDD/x2-noise.md` once S1 has acted on it.

## Answer

**Yes. A CryptoKit Swift Noise and an `@noble/*` TS Noise interoperate.** Both pass the official vectors byte for byte, and they complete handshakes against each other in both directions, then exchange transport messages.

**Use:**

| Flow | Protocol name | Why |
|---|---|---|
| Pairing (first contact, QR scanned) | `Noise_IKpsk1_25519_ChaChaPoly_SHA256`, psk = the QR's 32-byte one-time secret | Phone knows the host key from the QR. A wrong or expired secret fails the host's **first** read, before the host sends anything. |
| Reconnect (device already registered) | `Noise_IK_25519_ChaChaPoly_SHA256` | 1 round trip with mutual authentication. Host looks up the phone's static key (learned in message 1) in its device registry. |

## Run it

```sh
spikes/x2-noise/scripts/interop        # npm ci, swift build, swift test, npm test
spikes/x2-noise/scripts/fetch-vectors  # re-download vectors (pinned commits, sha256-checked) and regenerate the subset
```

You need Swift 6.2+ (Xcode 26) and Node ≥ 22.18, which strips TypeScript types itself, so there's no `tsc` or `tsx`. Everything runs on macOS: no Simulator, no sockets. Each side's interop test spawns the other side's peer and talks over stdin/stdout pipes.

## Layout

| Path | What |
|---|---|
| `swift/Sources/NoiseKit/Noise.swift` | Noise rev 34 on CryptoKit: `CipherState`, `SymmetricState`, `HandshakeState`, pattern + psk-modifier parsing (NN, NK, XX, IK, IX, KK). |
| `swift/Sources/NoiseKit/Interop.swift`, `swift/Sources/noise-peer/` | Interop script + stdio peer executable. |
| `ts/src/noise.ts` | The same state machine on `@noble/curves`, `@noble/ciphers`, `@noble/hashes` 2.4.0 (exact pins). |
| `ts/src/interop.ts`, `ts/src/peer.ts` | Interop script + stdio peer, the same CLI as the Swift peer. |
| `swift/Tests/…/NoiseVectorTests.swift`, `ts/test/vectors.test.ts` | Official vectors + unit tests (same names on both sides). |
| `swift/Tests/…/InteropTests.swift`, `ts/test/interop.test.ts` | Cross-language handshakes. |
| `vectors/subset.json` | 12 vectors: IK, IKpsk1, IKpsk2, XX × ChaChaPoly/AESGCM × SHA256, from [cacophony](https://github.com/haskell-cryptography/cacophony) `vectors/cacophony.txt` @ `18b7348` and [snow](https://github.com/mcginty/snow) `tests/vectors/snow.txt` @ `d00b360`. Raw files are gitignored; `vectors/SHA256SUMS` pins them. |

## Results

- **Official vectors:** all 12 pass in Swift and in TS: every handshake and transport ciphertext matches, plus the handshake hash where the vector has one. Two independent sources: cacophony (Haskell) and snow (Rust).
- **Cross-handshake:** 5 protocols in both directions (`IK` ChaChaPoly, `IK` AESGCM, `IKpsk1`, `IKpsk2`, `XX`). Each run does handshake payloads, 3 ping/pong transport messages each way, and a final exchange of the handshake hash. Both sides check `h` and the remote static key. Both test suites run this matrix, so each side has been tried as the in-process side and as the subprocess side.
- **Negative interop:** a wrong pairing secret (`IKpsk1`) and a wrong host key (`IK`) are rejected at message 1 in both directions.
- **Agreement on edge cases:** CryptoKit and noble both reject an all-zero (low-order) DH result (`lowOrderPublicKeyRejected`). Tampered transport ciphertexts fail on both.
- **The tests can fail:** flipping the ChaChaPoly nonce endianness in TS made 20 of 29 TS tests fail, both vectors and interop.

## Pattern choice

- **`IK` over `XX`.** The QR already delivers the host static key, which is exactly `IK`'s precondition. `XX` costs an extra half round trip, and its only advantage, not needing the host key in advance, doesn't apply here. `XX` only makes sense if some future flow has no QR. None is planned: the relay in D7 still pairs by QR.
- **A PSK fits the one-time pairing secret, but use `psk1`, not WireGuard's `psk2`.** In `IKpsk2` the psk is mixed in at the end of message 2. So a phone with the wrong secret passes the host's first read, the host answers, and the host can only tell from the phone's first transport message (`ikpsk2WrongSecretPassesFirstMessage`). In `IKpsk1` the psk is mixed in at the end of message 1, so the host rejects before replying (`ikpsk1WrongSecretFailsFirstMessage`, `pairingWrongSecretRejected`). Both are spec-listed patterns, and both are vector-tested here.
- **Alternative considered: plain `IK` with the secret in the message-1 payload.** That also works, because only the host's static key can decrypt it. But it needs an app-level constant-time compare, and it doesn't bind the secret into the session keys. With `psk1`, a wrong secret is just an AEAD failure inside Noise.
- **Cipher: ChaChaPoly.** It's the conventional Noise/WireGuard choice, fast in software on both sides, and doesn't depend on AES hardware. AESGCM passes everything too; switching is a one-word change in the protocol name.
- **Hash: SHA256.** CryptoKit has no BLAKE2 (below).

## What CryptoKit lacks, and how it's filled

| Gap | Fill |
|---|---|
| No Noise state machine | `NoiseKit`: about 390 lines following spec rev 34 (§5.1–5.3). |
| No BLAKE2s/BLAKE2b | Use the SHA256 suites. |
| Noise HKDF isn't a named API | Written with `HMAC<SHA256>`. CryptoKit's `HKDF<SHA256>` extract+expand with empty info gives the same bytes (`hkdfMatchesCryptoKit`), so either works. |
| Noise nonce format | CryptoKit takes any 12-byte nonce. We build 4 zero bytes + a 64-bit counter: little-endian for ChaChaPoly, big-endian for AESGCM. |
| `SealedBox` keeps ciphertext and tag separate | Concatenate on seal; split the last 16 bytes on open. |
| No X25519 in the Secure Enclave | The Noise static key lives in the Keychain (`ThisDeviceOnly`), as ARCHITECTURE §4 already says. |
| Fixed ephemerals for vectors | `Curve25519.KeyAgreement.PrivateKey(rawRepresentation:)` works, and `HandshakeState(e:)` is the test-only injection point. |

On the TS side, `@noble/*` covers every primitive (x25519, chacha20poly1305, gcm, sha256, hmac). Again only the state machine is ours.

## Risks

1. **Hand-rolled Noise, about 400 lines per language, unaudited.** Mitigations: vectors from two independent implementations, the cross-language matrix, a small surface (only the patterns we use). Mature off-the-shelf options are thin. There's no maintained Swift Noise. On TS, `noise-protocol` is libsodium-based, and `@chainsafe/libp2p-noise` is XX-only and tied to libp2p. Owning the state machine seems right, but an outside review before a public release would be prudent.
2. **The `IK` message-1 payload is replayable and not forward-secret** with respect to the host static key. Keep message 1 and message 2 payloads empty, and send `Hello` as the first transport message.
3. **Replay of message 1 during pairing.** A replayed message 1 still decrypts, but the replayer can't finish the handshake without the ephemeral private key. So the bridge should mark the secret used on the first valid message 1, and register the device only after the phone's first valid transport message.
4. **Choosing the pattern before message 1 is unauthenticated.** The host must know pair vs reconnect before reading message 1, e.g. from a one-byte mode in the first frame or a separate WebSocket path. Bind that mode (and the protocol version) into the **prologue**, so tampering just fails the handshake.
5. **Noise transport assumes in-order, lossless delivery.** WebSocket over TCP gives that. Reconnecting means a new handshake, and there's no session resumption at the crypto layer. A relay that could reorder or drop frames (D7 v2) would need explicit nonces.
6. **65535-byte limit per Noise message.** Protocol frames larger than about 64 KiB, such as artifacts in M3, must be chunked above Noise.
7. **noble is pure JS.** That's fine for control traffic. If M3 artifact throughput matters, measure it, and consider `node:crypto`'s chacha20-poly1305 behind the same `CipherState`.
8. **Rekey** is implemented but not exercised by vectors or used. M1 sessions are short-lived, so leave it off.

## Recommendation for S1

1. **Copy, don't depend.** Port `Noise.swift` into `ios/` under Transport (as `NoiseChannel: SecureChannel`'s engine) and `noise.ts` into `bridge/`. Bring the vector tests and `subset.json` along, so both CI suites keep proving the vectors.
2. **Replace process-spawning interop with golden fixtures.** One side writes a full handshake + transport transcript with fixed keys to `protocol/fixtures/noise/`, and the other side replays it, following PLAN §1's "Cross-language truth" rule. Keep a live Swift↔TS run as a local script only.
3. **Wire:** each WebSocket binary message carries one Noise message. The first frame starts with a one-byte mode (`pair` | `reconnect`). Prologue = `"dshm/1" ‖ mode`. Handshake payloads are empty, and `Hello` is the first transport frame.
4. **QR:** host static public key (32 B), a pairing secret (32 random bytes, used as the `psk1` value), address(es), and an expiry. Enforce secret expiry and single use in the bridge; S1 already has a Done when item for this.
5. **Keys:** the phone's X25519 Noise static key goes in the Keychain. Open question for S1: with `IK`, the phone's Noise static key already authenticates the device, so decide whether the separate Secure Enclave P-256 identity key (ARCHITECTURE §4) is still needed in M1, or only later (e.g. for signing approvals).
6. **ARCHITECTURE D6** can then name the concrete choice: `IKpsk1` for pairing, `IK` for reconnect, `25519_ChaChaPoly_SHA256`, prologue binding. Changing a `Dxx` entry is the user's call, so it's proposed here and not edited.
