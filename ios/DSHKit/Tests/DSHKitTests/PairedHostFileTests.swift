@testable import DSHCore
import DSHTestSupport
import DSHTransport
import Foundation
import Testing

struct PairedHostFileTests {
    private let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    private var file: URL { dir.appending(path: "hosts.json") }
    private var store: FilePairedHostStore { FilePairedHostStore(url: file) }

    private func host(_ key: UInt8) -> PairedHost {
        var host = PairedHost(name: "Host \(key)", addresses: [.localBridge()], hostKey: [key])
        host.tlsDeviceID = UUID().uuidString
        return host
    }

    @Test func failedRevocationPreservesBothCredentialsAndTheOtherHostReconnects() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = host(1), b = host(2)
        try store.save(a)
        try store.save(b)
        let original = try Data(contentsOf: file)
        func credential(_ origin: HostEnrollment) -> URL { dir.appending(path: origin.tlsDeviceID) }
        for host in [a, b] { try Data(host.name.utf8).write(to: credential(host.enrollment!)) }
        let pairing = Pairing(hosts: store)

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        #expect(throws: CocoaError.self) {
            try pairing.forget(a.enrollment!) { try FileManager.default.removeItem(at: credential($0)) }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try Data(contentsOf: file) == original)
        for host in [a, b] { #expect(try Data(contentsOf: credential(host.enrollment!)) == Data(host.name.utf8)) }

        try pairing.forget(a.enrollment!) { try FileManager.default.removeItem(at: credential($0)) }
        #expect(!FileManager.default.fileExists(atPath: credential(a.enrollment!).path))
        #expect(store.load() == [b])
        let survivor = try #require(store.load().first)
        let key = credential(survivor.enrollment!), bridge = FakeHost(hostName: "other host")
        let connection = HostConnection(endpoints: survivor.addresses, transport: { url in
            guard try Data(contentsOf: key) == Data(b.name.utf8) else { throw URLError(.userAuthenticationRequired) }
            return try await bridge.factory(url)
        })
        for _ in 0..<2 {
            try await connection.connect()
            #expect(try await connection.listTasks().hostName == "other host")
            await connection.disconnect()
        }
    }

    @Test func mutationsFailClosedAndPreserveCommittedCleanup() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = host(1), b = host(2)
        try store.save(a)
        let pairing = Pairing(hosts: store)
        #expect(throws: CocoaError.self) {
            try pairing.forget(a.enrollment!) { _ in throw CocoaError(.fileReadNoPermission) }
        }
        #expect(store.load().isEmpty)
        try store.save(b)
        let pending = try Data(contentsOf: file)
        try Data("invalid".utf8).write(to: file)
        for change in [{ try store.save(a) }, { try store.update(b) }, { try store.remove(id: a.id) },
                       { try store.removeAll() }, { try store.acknowledgeRemoval(of: a.enrollment!) }] {
            #expect(throws: DecodingError.self) { try change() }
            #expect(try Data(contentsOf: file) == Data("invalid".utf8))
        }
        try pending.write(to: file)
        var retried: [String] = []
        try Pairing(hosts: store).forget(a.enrollment!) { retried.append($0.tlsDeviceID) }
        #expect(retried == [a.tlsDeviceID!])
        #expect(store.load() == [b])
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try store.save(a) }
        #expect(try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    }

    @Test func independentWritersAndReadersPreserveAllRecords() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        var legacy = host(0)
        legacy.tlsDeviceID = nil
        try store.save(legacy)
        let hosts = (1...24).map { host(UInt8($0)) }
        for host in hosts { try store.save(host) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for var host in hosts {
                host.addresses = [.init(host: host.name, port: 1234)]
                let updated = host
                group.addTask { try store.update(updated) }
            }
            group.addTask { [legacy] in
                for _ in 0..<100 {
                    let raw = try JSONDecoder().decode([PairedHost].self, from: Data(contentsOf: file))
                    #expect(raw.count == hosts.count + 1)
                    #expect(raw.first == legacy)
                }
            }
            try await group.waitForAll()
        }
        #expect(store.load().map(\.addresses) == hosts.map { [.init(host: $0.name, port: 1234)] })
    }
}
