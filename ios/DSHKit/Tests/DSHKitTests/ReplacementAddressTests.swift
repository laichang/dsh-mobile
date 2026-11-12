@testable import DSHCore
import DSHTestSupport
import DSHTransport
import Foundation
import Testing

struct ReplacementAddressTests {
    func host(_ id: String, ports: [Int]) -> PairedHost {
        var host = PairedHost(name: id, addresses: ports.map { .localBridge(port: $0) }, hostKey: [1])
        host.tlsDeviceID = id
        return host
    }

    func connection(_ host: PairedHost, only reachable: HostEndpoint,
                    onChange: @escaping @Sendable ([HostEndpoint]) -> Void) -> HostConnection {
        let peer = FakeHost(hostName: host.name)
        return HostConnection(endpoints: host.addresses, enrollment: host.enrollment, transport: { url in
            guard url == reachable.webSocketURL() else { throw URLError(.cannotConnectToHost) }
            return try await peer.factory(url)
        }, onAddressesChange: onChange)
    }

    @Test func staleSuccessCannotReplaceOrResurrectAnEnrollment() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "hosts.json")
        let store = FilePairedHostStore(url: url), pairing = Pairing(hosts: store)
        let a = host("A", ports: [1001, 1002]), b = host("B", ports: [2001, 2002])
        try store.save(a)
        let writeA = pairing.addressWriter(for: a)
        let (orders, updates) = AsyncStream<[HostEndpoint]>.makeStream()
        let old = connection(a, only: a.addresses[1]) { updates.yield($0) }
        try await old.connect()
        updates.finish()
        var iterator = orders.makeAsyncIterator()
        let delayedOrder = try #require(await iterator.next())
        #expect(delayedOrder == Array(a.addresses.reversed()))
        try store.save(b)
        writeA(delayedOrder)
        await old.disconnect()

        let reopened = FilePairedHostStore(url: url)
        let saved = try #require(reopened.load().first)
        #expect(saved == b)
        let writeB = Pairing(hosts: reopened).addressWriter(for: saved)
        let current = connection(saved, only: b.addresses[1], onChange: writeB)
        try await current.connect()
        #expect(try await current.listTasks().hostName == "B")
        #expect(reopened.load().first?.addresses == Array(b.addresses.reversed()))
        await current.disconnect()

        _ = try reopened.retire(#require(b.enrollment))
        writeB(b.addresses)
        writeA(delayedOrder)
        #expect(reopened.load().isEmpty)
        #expect(Set(try reopened.pendingRemovals()) == Set([a.enrollment!, b.enrollment!]))
    }
}
