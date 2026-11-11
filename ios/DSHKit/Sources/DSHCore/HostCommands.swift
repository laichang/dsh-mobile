import DSHProtocol

public enum FollowUpMode: Sendable { case steer, queue }
public enum QueueAction: Sendable { case steer, remove }

package struct HostCapability: Sendable {
    let name: String

    package static let attachments = Self(name: DSHProtocolInfo.attachmentsCapability)
    package static let conversation = Self(name: DSHProtocolInfo.conversationCapability)
    package static let queue = Self(name: DSHProtocolInfo.queueCapability)
    package static let failures = Self(name: DSHProtocolInfo.failuresCapability)
    package static let approvals = Self(name: DSHProtocolInfo.approvalsCapability)
    package static let questions = Self(name: DSHProtocolInfo.questionsCapability)
    package static let models = Self(name: "models.v1")
    package static let devices = Self(name: "devices.v1")
}

extension HostSync.HostStatus {
    package func supports(_ capability: HostCapability) -> Bool { capabilities.contains(capability.name) }
}

package protocol HostCommands: HostDeviceManagement {
    func listWorkspaces() async throws -> WorkspaceList
    func modelCatalog() async throws -> ModelCatalog
    func selectModel(_ selection: ModelSelection, taskID: String) async throws
    func interrupt(taskID: String) async throws
    @discardableResult
    func editQueue(taskID: String, messageID: String, action: QueueAction) async throws -> QueuedMessage.Placement
    func answerApproval(id: String, allow: Bool) async throws
    func answerQuestion(id: String, answers: [String: AgentQuestion.Reply]) async throws
}

extension HostConnection: HostCommands {}
