# Baseline at 61b54169a58e7a20e9ca243dc96a6739b816e14a

The app, bridge, package and protocol sources match this revision. Xcode 26.0 compiled DSHCore for arm64 macOS 15 and arm64 iOS 26 Simulator. Each digester export contains 741 external declarations and 118 known declaration/type references. To export the complete signature inventory, run `scripts/check-core-api macos --inventory /tmp/core-macos.json` and repeat with `ios` and a separate output file. The platform-specific allowlists are in `scripts/core-api/`.

On each platform an external client importing only DSHCore can read `TaskSnapshot.title`. Both `host.addresses.first?.webSocketURL()` for a PairedHost and `task.stateRaw` for a CachedTask compile (exit 0). The two allowlists also record the HostEndpoint argument of both PairingOffer.init and AddressFailure.init.

## Baseline dependencies

| SwiftPM target | Direct dependencies |
| --- | --- |
| DSHActivity, DSHTransport, SystemCallbackDoubles | None |
| DSHProtocol | SwiftProtobuf |
| DSHCore | DSHProtocol, DSHTransport, SwiftProtobuf |
| DSHFeatures | DSHCore, DSHActivity |
| DSHTestSupport | DSHCore, DSHFeatures, DSHProtocol, DSHTransport, SwiftProtobuf |
| DSHKitTests | DSHCore, DSHFeatures, DSHProtocol, DSHTestSupport, DSHActivity, DSHTransport, SystemCallbackDoubles, SwiftProtobuf |

| Xcode target | Target dependencies | Linked package products |
| --- | --- | --- |
| dsh-mobile | LiveActivity | DSHCore, DSHFeatures, DSHTestSupport, DSHActivity |
| LiveActivity | None | DSHActivity |
| dsh-mobileUITests | dsh-mobile | DSHCore, DSHTransport |

## Baseline results

The round-trip demo passed all 95 bridge tests, 153 Swift package tests and four UI tests, with zero skips. The clean-install run starts a fresh local DSH profile, checks that the simulator has no app data container, and enrolls through the pairing screen. The first task's transcript includes “This reply is streamed through the dsh-mobile bridge.” The real host uses the local mock model.
