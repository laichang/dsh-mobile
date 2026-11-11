import DSHProtocol
import Foundation

public struct PairedDevice: Identifiable, Sendable {
    public let id: String
    public let isCurrent: Bool
    public let pairedAt: Date
    public let lastSeenAt: Date
}

public struct DeviceAuditEntry: Identifiable, Sendable {
    public let id: String
    public let at: Date
    public let actor: String
    public let device: String
    public let action: String
    public let detail: String
}

public struct DeviceAuditPage: Sendable {
    public let entries: [DeviceAuditEntry]
    public let nextBeforeID: String
}

public enum DeviceRevocation: Sendable {
    case thisDevice
    case remaining([PairedDevice])
}

public protocol HostDeviceManagement: Sendable {
    func listDevices() async throws -> [PairedDevice]
    func revokeDevice(_ device: PairedDevice) async throws -> DeviceRevocation
    func audit(beforeID: String) async throws -> DeviceAuditPage
}

extension HostDeviceManagement {
    public func audit() async throws -> DeviceAuditPage { try await audit(beforeID: "") }
}

extension HostConnection: HostDeviceManagement {
    public func listDevices() async throws -> [PairedDevice] {
        try await request(.listDevices(.init())).pairedDevices()
    }

    public func revokeDevice(_ device: PairedDevice) async throws -> DeviceRevocation {
        do {
            let response = try await request(.revokeDevice(.with { $0.deviceID = device.id }))
            let remaining = try response.pairedDevices()
            return device.isCurrent ? .thisDevice : .remaining(remaining)
        } catch where device.isCurrent && Self.isDeviceRefusal(error) {
            // The host can close this phone's socket before its revoke response arrives.
            return .thisDevice
        }
    }

    public func audit(beforeID: String) async throws -> DeviceAuditPage {
        let response = try await request(.listAudit(.with { $0.beforeID = beforeID }))
        guard case .auditPage(let page)? = response.body else { throw HostConnectionError.unexpectedResponse }
        return DeviceAuditPage(entries: page.entries.map {
            DeviceAuditEntry(id: $0.id, at: date($0.atMs), actor: $0.actor, device: $0.device,
                             action: $0.action, detail: $0.detail)
        }, nextBeforeID: page.nextBeforeID)
    }
}

private extension Dshm_V1_Response {
    func pairedDevices() throws -> [PairedDevice] {
        guard case .deviceList(let list)? = body else { throw HostConnectionError.unexpectedResponse }
        return list.devices.map {
            PairedDevice(id: $0.id, isCurrent: $0.id == list.currentDeviceID,
                         pairedAt: date($0.pairedAtMs), lastSeenAt: date($0.lastSeenAtMs))
        }
    }
}

private func date(_ milliseconds: Int64) -> Date {
    Date(timeIntervalSince1970: Double(milliseconds) / 1000)
}
