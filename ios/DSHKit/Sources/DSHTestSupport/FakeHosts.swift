#if DEBUG
import DSHTransport
import DSHCore
import DSHFeatures
import DSHProtocol
import Foundation

/// The paired devices and audit records of a fake host (`devices.v1`), like the bridge's
/// `ListDevices`, `ListAudit` and `RevokeDevice` (bridge/src/server.ts). A revoke of the current
/// device answers first, then the host closes that device's connections and refuses new ones.
public struct FakeDevices: Sendable {
    public static let capability = "devices.v1"

    public var closeBeforeRevokeResponse = false
    public var current: String
    package var devices: [Dshm_V1_PairedDevice]
    /// Newest first.
    package var audit: [Dshm_V1_AuditEntry]
    /// Entries in one `AuditPage`; the rest come with "load older".
    public var pageSize: Int

    package init(current: String, devices: [Dshm_V1_PairedDevice], audit: [Dshm_V1_AuditEntry], pageSize: Int = 3) {
        self.current = current
        self.devices = devices
        self.audit = audit
        self.pageSize = pageSize
    }

    static func handles(_ body: Dshm_V1_Request.OneOf_Body) -> Bool {
        switch body {
        case .listDevices, .listAudit, .revokeDevice: true
        default: false
        }
    }

    /// The answer to a devices request, and whether the current device lost its access.
    mutating func answer(_ body: Dshm_V1_Request.OneOf_Body) -> (Dshm_V1_Response.OneOf_Body, revokedCurrent: Bool)? {
        switch body {
        case .listDevices:
            return (.deviceList(list), false)
        case .listAudit(let request):
            let start = request.beforeID.isEmpty ? 0 : (audit.firstIndex { $0.id == request.beforeID }).map { $0 + 1 } ?? audit.count
            let page = Array(audit[start...].prefix(pageSize))
            var result = Dshm_V1_AuditPage()
            result.entries = page
            if start + page.count < audit.count, let last = page.last { result.nextBeforeID = last.id }
            return (.auditPage(result), false)
        case .revokeDevice(let request):
            guard devices.contains(where: { $0.id == request.deviceID }) else {
                var error = Dshm_V1_Error()
                error.code = "devices/failed"
                error.message = "No paired device has this id."
                return (.error(error), false)
            }
            devices.removeAll { $0.id == request.deviceID }
            audit.insert(Self.entry(id: "audit-\(audit.count + 1)", minutesAgo: 0, action: "Device revoked",
                                    detail: request.deviceID, device: current), at: 0)
            return (.deviceList(list), request.deviceID == current)
        default:
            return nil
        }
    }

    private var list: Dshm_V1_DeviceList {
        var list = Dshm_V1_DeviceList()
        list.currentDeviceID = current
        list.devices = devices
        return list
    }

    package static func device(_ id: String, pairedDaysAgo: Int, seenMinutesAgo: Int) -> Dshm_V1_PairedDevice {
        var device = Dshm_V1_PairedDevice()
        device.id = id
        device.pairedAtMs = ms(minutesAgo: pairedDaysAgo * 24 * 60)
        device.lastSeenAtMs = ms(minutesAgo: seenMinutesAgo)
        return device
    }

    package static func entry(id: String, minutesAgo: Int, action: String, detail: String, device: String,
                             actor: String = "owner") -> Dshm_V1_AuditEntry {
        var entry = Dshm_V1_AuditEntry()
        entry.id = id
        entry.atMs = ms(minutesAgo: minutesAgo)
        entry.actor = actor
        entry.device = device
        entry.action = action
        entry.detail = detail
        return entry
    }

    static func ms(minutesAgo: Int) -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) - Int64(minutesAgo) * 60_000 }
}

/// The hosts of screens H, X2 and X3 (`-DSHMFakeBridge hosts…`): MacBook-Pro (online, with
/// a model catalog, devices and audit records), hk-1 (its DSH is too old for the bridge) and
/// 公司-PC (a session waits on the user there). A UI test stops and starts the reachable hosts with the Darwin
/// notifications `hostsDown` and `hostsUp`, and revokes this phone on MacBook-Pro from another
/// client with `hostsRevoke` (the app's `FakeHostsSwitch`).
public enum FakeHosts {
    public enum Variant: String, Sendable, CaseIterable {
        /// The three hosts of screen H.
        case three = "hosts"
        /// Only MacBook-Pro: a revoke of this device leaves no host, and the app shows 08.
        case one = "hosts-one"
    }

    public static let macName = "MacBook-Pro"
    public static let hkName = "hk-1"
    public static let officeName = "公司-PC"
    public static let thisDevice = "dshm-a3f9c21e"
    public static let otherDevice = "dshm-77b0e4d2"
    public static let hostsDown = "chang.dsh-mobile.fake.hosts-down"
    public static let hostsUp = "chang.dsh-mobile.fake.hosts-up"
    /// Another client revokes this phone on MacBook-Pro (`FakeHost.revokeThisDevice()`).
    public static let hostsRevoke = "chang.dsh-mobile.fake.hosts-revoke"

    /// MacBook-Pro's records, newest first: two fit on the first page, one more on the next.
    public static func macDevices() -> FakeDevices {
        FakeDevices(
            current: thisDevice,
            devices: [FakeDevices.device(thisDevice, pairedDaysAgo: 3, seenMinutesAgo: 0),
                      FakeDevices.device(otherDevice, pairedDaysAgo: 16, seenMinutesAgo: 14 * 24 * 60)],
            audit: [FakeDevices.entry(id: "audit-3", minutesAgo: 20, action: "Approval allowed",
                                      detail: "bash rm -rf ~/Desktop/Q3/tmp", device: thisDevice),
                    FakeDevices.entry(id: "audit-2", minutesAgo: 62, action: "Approval denied",
                                      detail: "write reports/week45.md", device: "web"),
                    FakeDevices.entry(id: "audit-1", minutesAgo: 26 * 60, action: "Device revoked",
                                      detail: "dshm-1c0045aa", device: thisDevice)],
            pageSize: 2)
    }

    /// MacBook-Pro's model catalog (`models.v1`), so screen H shows its default model.
    public static let defaultModelName = "DeepSeek-V41-Flash"
    static var macPickers: FakeBridge.Pickers {
        .init(catalog: FakePickers.catalog(failures: []),
              workspaces: .init(defaultPath: FakePickers.home, recentPaths: [FakePickers.q3]))
    }

    /// The hosts that a UI test can stop and start: every host of the variant except hk-1.
    public static func hosts(_ variant: Variant) -> (configs: [TaskListStore.HostConfig], switchable: [FakeHost]) {
        var hosts: [(String, FakeHost)] = []
        hosts.append((macName, FakeHost(script: .init(reply: ["Reply ", "from ", macName], chunkDelay: .milliseconds(200)),
                                        hostName: macName, pickers: macPickers, devices: macDevices())))
        if variant == .three {
            hosts.append((hkName, FakeHost(hostName: hkName, incompatibleDsh: ("0.8.2", "0.9.x"))))
            var waiting = Dshm_V1_TaskSummary()
            waiting.taskID = "fake-office-install"
            waiting.title = "Install the printer driver"
            waiting.state = .waitingOnUser
            waiting.updatedAtMs = FakeDevices.ms(minutesAgo: 30)
            waiting.createdAtMs = waiting.updatedAtMs - 60_000
            hosts.append((officeName, FakeHost(hostName: officeName, seed: [waiting])))
        }
        let configs = hosts.enumerated().map { index, host in
            TaskListStore.HostConfig(key: "fake:\(host.0)", connection: HostConnection(
                endpoint: HostEndpoint.localBridge(port: 47801 + index), channel: PlaintextChannel(),
                transport: host.1.factory), name: host.0)
        }
        return (configs, hosts.filter { $0.0 != hkName }.map(\.1))
    }
}
#endif
