import DSHCore
import DSHTestSupport
import Testing

struct WorkspaceListTests {
    @Test(arguments: [[], ["/srv/z", "/srv/a"]])
    func hostReturnsDefaultAndOrderedRecentPaths(_ paths: [String]) async throws {
        let expected = WorkspaceList(defaultPath: "/srv/home", recentPaths: paths)
        let host = FakeHost(pickers: .init(catalog: .init(), workspaces: expected))
        let connection = HostConnection(endpoint: .localBridge(port: 47801), transport: host.factory)
        try await connection.connect()
        let result = try await connection.listWorkspaces()
        await connection.disconnect()
        #expect(result == expected)
    }
}
