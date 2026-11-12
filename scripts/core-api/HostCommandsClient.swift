import DSHCore

func exercise(_ host: HostSync.HostConfig, file: FileAttachment, model: ModelSelection,
              question: AgentQuestion, device: PairedDevice) async throws {
    let commands = host.commands
    try await commands.connect()
    let resumed = try await commands.resume(logID: "", afterSeq: 0)
    let listing = try await commands.listTasks()
    let workspace = try await commands.listWorkspaces()
    let upload = try await commands.upload(file) { _ in }
    let task = try await commands.createTask(prompt: listing.hostName, selection: model,
                                             workspace: workspace.defaultPath, uploadIDs: [upload])
    let message = try await commands.sendMessage(taskID: task, text: resumed.hostName, mode: .queue, uploadIDs: [])
    try await commands.editQueue(taskID: task, messageID: message, action: .steer)
    _ = try await commands.readSession(task)
    _ = try await commands.modelCatalog()
    try await commands.selectModel(model, taskID: task)
    try await commands.answerQuestion(id: question.requestID, answers: question.replies(typed: "ok"))
    try await commands.answerApproval(id: "approval", allow: true)
    try await commands.interrupt(taskID: task)
    _ = try await commands.listDevices()
    _ = try await commands.audit()
    _ = try await commands.revokeDevice(device)
    await commands.disconnect()
}
