#if DEBUG
import DSHCore
import DSHProtocol
import Foundation

/// S14 · two FakeBridge hosts with sessions in workspaces, as on screen 02 (`-DSHMFakeBridge drawer…`).
/// The sessions are already on the hosts, as if the Web client or the phone made them earlier.
public enum FakeDrawer {
    public enum Variant: String, Sendable, CaseIterable {
        /// Both hosts online, with `drawer.v1`.
        case online = "drawer"
        /// The office host is offline. Its sessions come from the cache of an earlier launch.
        case officeOffline = "drawer-office-offline"
        /// Both hosts online, with an older bridge: no `drawer.v1`, no workspaces.
        case noCapability = "drawer-v0"
    }

    public static let macName = "MacBook-Pro"
    public static let officeName = "Office-PC"
    public static let q3 = "/Users/laichang/Desktop/Q3"
    public static let repo = "/Users/laichang/code/dsh-mobile"
    public static let office = "/Users/laichang/Documents/office"

    /// One row of the scenario: title, state, workspace, and minutes before the start of this hour.
    struct Session {
        var id: String
        var title: String
        var state: Dshm_V1_TaskState
        var workspace: String
        var minutesAgo: Int64
        var external = false
    }

    static let mac: [Session] = [
        Session(id: "fake-q3-ppt", title: "整理 Q3 报表成 PPT", state: .waitingOnUser, workspace: q3, minutesAgo: 2),
        Session(id: "fake-q3-slides", title: "Q3 summary slides", state: .completed, workspace: q3, minutesAgo: 10),
        Session(id: "fake-web-first", title: "网页第一条", state: .completed, workspace: q3, minutesAgo: 60 * 20, external: true),
        Session(id: "fake-ci", title: "修复 CI 挂掉的测试并提 PR", state: .running, workspace: repo, minutesAgo: 5),
    ]
    static let officeSessions: [Session] = [
        Session(id: "fake-office-driver", title: "Install the printer driver", state: .waitingOnUser, workspace: office, minutesAgo: 30),
        Session(id: "fake-office-report", title: "Weekly report", state: .completed, workspace: office, minutesAgo: 120, external: true),
    ]

    /// The number of sessions that wait on the user, across both hosts (the badge, and 等我处理).
    public static let waitingCount = (mac + officeSessions).filter { $0.state == .waitingOnUser }.count

    /// The two hosts of `variant`, each its own `FakeHost` behind its own connection.
    public static func hosts(_ variant: Variant) -> [TaskListStore.HostConfig] {
        let capable = variant != .noCapability
        return [(macName, mac, true), (officeName, officeSessions, variant != .officeOffline)].enumerated().map { index, host in
            let (name, sessions, reachable) = host
            let fake = FakeHost(script: .init(reply: ["Reply ", "from ", name], chunkDelay: .milliseconds(200)),
                                hostName: name, reachable: reachable,
                                seed: sessions.map { summary($0, workspace: capable) },
                                extraCapabilities: capable ? [DrawerTree.capability] : [])
            let endpoint = HostEndpoint.localBridge(port: 47801 + index)
            return .init(key: "fake:\(name)", connection: HostConnection(endpoint: endpoint, channel: PlaintextChannel(),
                         transport: fake.factory), name: name)
        }
    }

    static func summary(_ session: Session, workspace: Bool) -> Dshm_V1_TaskSummary {
        // Fixed within the hour, so a relaunch sends the same times and read marks stay.
        let hour = Int64(Date().timeIntervalSince1970 / 3600) * 3_600_000
        var s = Dshm_V1_TaskSummary()
        s.taskID = session.id
        s.title = session.title
        s.state = session.state
        s.updatedAtMs = hour - session.minutesAgo * 60_000
        s.createdAtMs = s.updatedAtMs - 60_000
        s.externalSession = session.external
        if workspace { s.workspace = session.workspace }
        return s
    }
}
#endif
