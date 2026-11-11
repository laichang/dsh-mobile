#if DEBUG
import DSHCore
import DSHTransport
import Foundation

/// Recreates the two independent stores left by the previous app on the test device.
public enum LegacyPairingFixture {
    public static func install(in store: any PairedHostStore) throws {
        let oldKey = KeychainData(service: "chang.dsh-mobile.noise", account: "device-static-x25519")
        let bytes = try oldKey.readOrCreate { Data(repeating: 19, count: 32) }
        guard try oldKey.read() == bytes else { throw CocoaError(.fileWriteUnknown) }
        let record = PairedHost(name: "Previous Mac", addresses: [.localBridge()], hostKey: Array(repeating: 22, count: 32))
        try store.removeAll()
        try store.save(record)
    }
}
#endif
