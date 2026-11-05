import DSHProtocol
import Foundation

public struct Approval: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let taskID: String
    public let tool: String
    public let arguments: String
    public let reason: String

    init(_ pending: Dshm_V1_ApprovalPending) {
        id = pending.id
        taskID = pending.taskID
        tool = pending.tool
        arguments = pending.argumentsJson
        reason = pending.reason
    }

    public var command: String? {
        let fields = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any]
        return fields?["command"] as? String
    }
}
