import DSHCore
import Foundation
import Observation

@MainActor
@Observable
public final class TaskComposer {
    public internal(set) var hostKey: String?

    init(prompt: String, hostKey: String?) {
        self.prompt = prompt
        self.hostKey = hostKey
    }

    public var sessionDrafts: [String: String] = [:]
    public var prompt: String
    /// The files on composer 01, in order: sent to the host before the task, then dropped.
    public private(set) var newTaskAttachments: [ComposerAttachment] = []
    /// The files on each session page's composer, by task key, for its next follow-up.
    public private(set) var followUpAttachments: [String: [ComposerAttachment]] = [:]
    public var selections: [String: ModelSelection] = [:]
    public private(set) var workspaces: [String: String] = [:]

    public func chooseWorkspace(_ path: String?, hostKey: String) {
        workspaces[hostKey] = path
        sendError = nil
    }

    public func useHostDefault(hostKey: String) {
        selections.removeValue(forKey: hostKey)
        sendError = nil
    }

    public private(set) var isSending = false
    public internal(set) var sendError: String?
    /// The texts of follow-ups that the task did not run because it stopped, for the
    /// composer of the task's page. They leave the store when the page takes them.
    public internal(set) var returnedDrafts: [String: [String]] = [:]

    public func takeReturnedDrafts(for taskKey: String) -> [String] {
        returnedDrafts.removeValue(forKey: taskKey) ?? []
    }

    public func attachments(on target: AttachTarget) -> [ComposerAttachment] {
        switch target {
        case .composer: newTaskAttachments
        case .followUp(let key): followUpAttachments[key] ?? []
        }
    }

    func setAttachments(_ list: [ComposerAttachment], on target: AttachTarget) {
        switch target {
        case .composer: newTaskAttachments = list
        case .followUp(let key): followUpAttachments[key] = list.isEmpty ? nil : list
        }
    }

    /// Adds a file at the end of a composer. A file over the limit stays, with the error on
    /// its chip, and the send waits until it is removed. Returns false when the composer already
    /// has `Attachments.maxCount` files.
    @discardableResult
    public func attach(_ attachment: FileAttachment, to target: AttachTarget = .composer) -> Bool {
        var list = attachments(on: target)
        guard list.count < Attachments.maxCount else { return false }
        list.append(ComposerAttachment(attachment))
        setAttachments(list, on: target)
        if target == .composer { sendError = nil }
        return true
    }

    public func removeAttachment(_ id: UUID, from target: AttachTarget = .composer) {
        setAttachments(attachments(on: target).filter { $0.id != id }, on: target)
        if target == .composer { sendError = nil }
    }

    private func setStatus(_ status: ComposerAttachment.Status, of id: UUID, on target: AttachTarget) {
        var list = attachments(on: target)
        guard let at = list.firstIndex(where: { $0.id == id }) else { return }
        list[at].status = status
        setAttachments(list, on: target)
    }

    func uploadProgress(on target: AttachTarget) -> HostSync.UploadProgress {
        { [weak self] id, result in
            switch result {
            case .success(let fraction): self?.setStatus(.uploading(fraction), of: id, on: target)
            case .failure(let error): self?.setStatus(.failed(String(describing: error)), of: id, on: target)
            }
        }
    }

    func consume(_ files: [FileAttachment], on target: AttachTarget) {
        let sent = Set(files.map(\.id))
        setAttachments(attachments(on: target).filter { !sent.contains($0.id) }, on: target)
    }

    /// Whether a composer's files can go: none is over the limit.
    func attachmentsCanSend(on target: AttachTarget) -> Bool {
        !attachments(on: target).contains { $0.status == .tooLarge }
    }

    var canSend: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending && attachmentsCanSend(on: .composer)
    }

    /// Sends the composer's prompt as a new task on the selected host. Returns the new task's key,
    /// or nil with `sendError` set (for example, the host is offline).
    @discardableResult
    func send(on link: HostSync, waitOnline: (HostSync) async -> Bool, hostName: () -> String) async -> String? {
        let text = prompt
        let files = newTaskAttachments.map(\.attachment)
        let selection = selections[link.key]
        let workspace = workspaces[link.key]
        isSending = true
        sendError = nil
        defer { isSending = false }
        guard await waitOnline(link) else {
            let name = hostName()
            if case .needsBridgeUpdate(let version, let supported) = link.reachability {
                sendError = "\(name) needs a bridge update. Installed DSH: \(version). Supported DSH: \(supported)."
            } else {
                sendError = "\(name) is offline. The task was not sent."
            }
            return nil
        }
        do {
            let key = try await link.createTask(prompt: text, selection: selection, workspace: workspace,
                                                attachments: files,
                                                progress: uploadProgress(on: .composer))
            if prompt == text { prompt = "" }
            consume(files, on: .composer)
            workspaces[link.key] = nil // A workspace choice is for this one new session.
            return key
        } catch {
            sendError = String(describing: error)
            return nil
        }
    }
}
