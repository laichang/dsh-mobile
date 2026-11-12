import DSHProtocol
import Foundation
import SwiftProtobuf

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

public protocol HostCommands: HostDeviceManagement {
    func connect() async throws
    func disconnect() async
    func resume(logID: String, afterSeq: UInt64) async throws -> ResumeResult
    func listTasks() async throws -> TaskListing
    func createTask(prompt: String, selection: ModelSelection?, workspace: String?, uploadIDs: [String]) async throws -> String
    @discardableResult
    func sendMessage(taskID: String, text: String, mode: FollowUpMode, uploadIDs: [String]) async throws -> String
    func upload(_ file: FileAttachment, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> String
    func readSession(_ id: String) async throws -> SessionHistory
    func listWorkspaces() async throws -> WorkspaceList
    func modelCatalog() async throws -> ModelCatalog
    func selectModel(_ selection: ModelSelection, taskID: String) async throws
    func interrupt(taskID: String) async throws
    @discardableResult
    func editQueue(taskID: String, messageID: String, action: QueueAction) async throws -> QueuedMessage.Placement
    func answerApproval(id: String, allow: Bool) async throws
    func answerQuestion(id: String, answers: [String: AgentQuestion.Reply]) async throws
}

public enum HostProtocol {
    public static let version = DSHProtocolInfo.version
}

extension HostConnection: HostCommands {
    /// Starts a task; its output arrives on `events`.
    public func createTask(prompt: String, selection: ModelSelection? = nil, workspace: String? = nil,
                           uploadIDs: [String] = []) async throws -> String {
        var create = Dshm_V1_CreateTask()
        create.prompt = prompt
        create.uploadIds = uploadIDs
        if let workspace {
            guard capabilities.contains("workspaces.v1") else {
                throw HostConnectionError.bridge(code: "workspace/unavailable", message: "This host cannot select the requested workspace.")
            }
            create.workspace = workspace
        }
        if let selection {
            guard capabilities.contains("models.v1") else {
                throw HostConnectionError.bridge(code: "model/unavailable", message: "This host cannot select the requested model.")
            }
            create.modelSelection = selection.wire
        }
        let response = try await request(.createTask(create))
        guard case .taskCreated(let created)? = response.body else { throw HostConnectionError.unexpectedResponse }
        return created.taskID
    }

    /// Sends a file to the host in parts and returns its upload id for `createTask`
    /// or `sendMessage`. A file over `Attachments.maxBytes` is refused here, before any frame.
    /// The host checks the size and the SHA-256; a refusal throws `HostConnectionError.bridge`.
    /// `progress` gets the fraction sent after each part the host acknowledged.
    public func upload(_ file: FileAttachment,
                       progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }) async throws -> String {
        guard capabilities.contains(DSHProtocolInfo.attachmentsCapability) else {
            throw HostConnectionError.bridge(code: "upload/unavailable", message: "This host cannot take attachments.")
        }
        guard !file.isTooLarge else {
            throw HostConnectionError.bridge(code: "upload/too-large",
                                             message: "\(file.name) is larger than \(Attachments.sizeText(Attachments.maxBytes)).")
        }
        let uploadID = UUID().uuidString.lowercased()
        var begin = Dshm_V1_UploadBegin()
        begin.uploadID = uploadID
        begin.mediaType = file.mediaType
        begin.name = file.name
        begin.size = UInt64(file.data.count)
        begin.sha256 = Attachments.sha256(file.data)
        _ = try await request(.uploadBegin(begin))
        let parts = Attachments.parts(of: file.data)
        for (index, part) in parts.enumerated() {
            var chunk = Dshm_V1_UploadChunk()
            chunk.uploadID = uploadID
            chunk.index = UInt32(index)
            chunk.data = part
            _ = try await request(.uploadChunk(chunk))
            await progress(Double(index + 1) / Double(parts.count))
        }
        var end = Dshm_V1_UploadEnd()
        end.uploadID = uploadID
        let response = try await request(.uploadEnd(end))
        guard case .uploadStaged(let staged)? = response.body, staged.uploadID == uploadID else {
            throw HostConnectionError.unexpectedResponse
        }
        return uploadID
    }

    public func interrupt(taskID: String) async throws {
        var command = Dshm_V1_Interrupt()
        command.taskID = taskID
        let response = try await request(.interrupt(command))
        guard case .interruptAccepted? = response.body else { throw HostConnectionError.unexpectedResponse }
    }

    /// One more message into the DSH session of `taskID`. Returns the message's ID once DSH
    /// accepted it; its `.userMessage` event and the new turn's events follow.
    @discardableResult
    public func sendMessage(taskID: String, text: String, mode: FollowUpMode = .steer,
                            uploadIDs: [String] = []) async throws -> String {
        var message = Dshm_V1_SendMessage()
        message.taskID = taskID
        message.text = text
        message.mode = mode == .steer ? .steer : .queue
        message.uploadIds = uploadIDs // Staged files, after the text
        let response = try await request(.sendMessage(message))
        guard case .messageAccepted(let accepted)? = response.body else { throw HostConnectionError.unexpectedResponse }
        return accepted.messageID
    }

    /// Moves a waiting follow-up into the running turn (`.steer`), or takes it out
    /// (`.remove`). Returns where it waits now; its `.queuedMessage` event follows.
    @discardableResult
    public func editQueue(taskID: String, messageID: String, action: QueueAction) async throws -> QueuedMessage.Placement {
        guard capabilities.contains(DSHProtocolInfo.queueCapability) else {
            throw HostConnectionError.bridge(code: "request/unsupported", message: "This host cannot change the queue.")
        }
        var edit = Dshm_V1_EditQueue()
        edit.taskID = taskID
        edit.messageID = messageID
        edit.action = action == .steer ? .steer : .remove
        let response = try await request(.editQueue(edit))
        guard case .queueEdited(let edited)? = response.body else { throw HostConnectionError.unexpectedResponse }
        return QueuedMessage.Placement(wire: edited.placement)
    }

    public func modelCatalog() async throws -> ModelCatalog {
        let response = try await request(.getModelCatalog(.init()))
        guard case .modelCatalog(let catalog)? = response.body else { throw HostConnectionError.unexpectedResponse }
        return ModelCatalog(catalog)
    }

    public func selectModel(_ selection: ModelSelection, taskID: String) async throws {
        var select = Dshm_V1_SelectModel()
        select.taskID = taskID
        select.selection = selection.wire
        let response = try await request(.selectModel(select))
        guard case .modelSelected(let accepted)? = response.body,
              accepted.taskID == taskID, accepted.hasSelection, ModelSelection(accepted.selection) == selection else { throw HostConnectionError.unexpectedResponse }
    }

    public func answerApproval(id: String, allow: Bool) async throws {
        var answer = Dshm_V1_AnswerApproval()
        answer.id = id
        answer.decision = allow ? .allowOnce : .deny
        let response = try await request(.answerApproval(answer))
        guard case .approvalResolved(let result)? = response.body, result.id == id,
              result.outcome == (allow ? .allowed : .denied) else { throw HostConnectionError.unexpectedResponse }
    }

    /// Answers a held agent question: for each question, the chosen labels or the typed text.
    public func answerQuestion(id: String, answers: [String: AgentQuestion.Reply]) async throws {
        var answer = Dshm_V1_AnswerQuestion()
        answer.id = id
        answer.answers = answers.sorted { $0.key < $1.key }.map { questionID, reply in
            var a = Dshm_V1_QuestionAnswer()
            a.questionID = questionID
            a.selected = reply.selected
            a.custom = reply.custom
            return a
        }
        let response = try await request(.answerQuestion(answer))
        guard case .questionResolved(let result)? = response.body, result.id == id else { throw HostConnectionError.unexpectedResponse }
    }

    /// Read backwards at one DSH event cut so a concurrent Web turn cannot shift page boundaries.
    public func readSession(_ id: String) async throws -> SessionHistory {
        var requestPage = Dshm_V1_ReadSession()
        requestPage.taskID = id
        var pages: [[Dshm_V1_SessionMessage]] = []
        while true {
            try Task.checkCancellation()
            let response = try await request(.readSession(requestPage))
            guard case .sessionPage(let page) = response.body else { throw HostConnectionError.unexpectedResponse }
            guard !requestPage.hasThroughSeq || page.throughSeq == requestPage.throughSeq else {
                throw HostConnectionError.unexpectedResponse
            }
            pages.append(page.messages)
            requestPage.throughSeq = page.throughSeq
            guard page.hasNextBeforeSeq else { break }
            guard !requestPage.hasBeforeSeq || page.nextBeforeSeq < requestPage.beforeSeq else {
                throw HostConnectionError.unexpectedResponse
            }
            requestPage.beforeSeq = page.nextBeforeSeq
        }
        var result = Dshm_V1_SessionPage()
        result.throughSeq = requestPage.throughSeq
        result.messages = pages.reversed().flatMap { $0 }
        return try SessionHistory(result, cacheData: result.serializedData())
    }

    /// Every task the host knows, newest first.
    public func listTasks() async throws -> TaskListing {
        let response = try await request(.listTasks(Dshm_V1_ListTasks()))
        guard case .taskList(let list)? = response.body else { throw HostConnectionError.unexpectedResponse }
        return TaskListing(tasks: list.tasks.map(TaskSnapshot.init), logID: list.logID, hostName: list.hostName)
    }

    /// Asks for every logged event after `afterSeq` of log `logID`, then live events. The
    /// replayed events reach `events` before this returns.
    public func resume(logID: String, afterSeq: UInt64) async throws -> ResumeResult {
        var resume = Dshm_V1_Resume()
        resume.logID = logID
        resume.afterSeq = afterSeq
        let response = try await request(.resume(resume))
        guard case .resumed(let r)? = response.body else { throw HostConnectionError.unexpectedResponse }
        return ResumeResult(logID: r.logID, headSeq: r.headSeq, hostName: r.hostName, reset: r.reset, replayed: r.replayed)
    }

    public func listWorkspaces() async throws -> WorkspaceList {
        let response = try await request(.listWorkspaces(.init()))
        guard case .workspaceList(let list)? = response.body else { throw HostConnectionError.unexpectedResponse }
        return WorkspaceList(defaultPath: list.defaultPath, recentPaths: list.recentPaths)
    }
}
