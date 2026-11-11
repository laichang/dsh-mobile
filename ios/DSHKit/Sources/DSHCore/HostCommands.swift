import DSHProtocol

public enum FollowUpMode: Sendable { case steer, queue }
public enum QueueAction: Sendable { case steer, remove }

public struct HostCapability: Sendable {
    let name: String

    public static let drawer = Self(name: "drawer.v1")
    public static let workspaces = Self(name: "workspaces.v1")
    public static let interrupt = Self(name: DSHProtocolInfo.interruptCapability)
    public static let transcript = Self(name: DSHProtocolInfo.transcriptCapability)
    public static let attachments = Self(name: DSHProtocolInfo.attachmentsCapability)
    public static let conversation = Self(name: DSHProtocolInfo.conversationCapability)
    public static let queue = Self(name: DSHProtocolInfo.queueCapability)
    public static let failures = Self(name: DSHProtocolInfo.failuresCapability)
    public static let approvals = Self(name: DSHProtocolInfo.approvalsCapability)
    public static let questions = Self(name: DSHProtocolInfo.questionsCapability)
    public static let models = Self(name: "models.v1")
    public static let devices = Self(name: "devices.v1")
}

extension HostSync.HostStatus {
    public func supports(_ capability: HostCapability) -> Bool { capabilities.contains(capability.name) }
    public var hasCapabilities: Bool { !capabilities.isEmpty }
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

public enum HostProtocol {
    public static let version = DSHProtocolInfo.version
}
