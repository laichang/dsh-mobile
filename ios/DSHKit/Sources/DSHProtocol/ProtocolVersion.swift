/// Constants for protocol/frame.proto. Generated message types live in Generated/ (scripts/codegen).
public enum DSHProtocolInfo {
    /// Sent in `Hello.protocol_version`. Must match the bridge's PROTOCOL_VERSION.
    public static let version: UInt32 = 1
    /// Capability the bridge advertises for the core CreateTask / AssistantChunk / TaskEnded.
    public static let tasksCapability = "tasks.v1"
    /// The bridge sends `MilestoneAdded` events (protocol/milestones.proto).
    public static let milestonesCapability = "milestones.v1"
    public static let approvalsCapability = "approvals.v1"
    public static let interruptCapability = "interrupt.v1"
    /// ListTasks, Resume and `Event.host_seq` (protocol/s2.proto).
    public static let resumeCapability = "resume.v1"
    /// The bridge sends `TranscriptBlock` events (protocol/transcript.proto).
    public static let transcriptCapability = "transcript.v1"
    /// SendMessage, MessageAccepted and UserMessage (protocol/conversation.proto).
    public static let conversationCapability = "conversation.v1"
    /// Follow-ups while a task runs: `QueuedMessage`, `EditQueue`, `QueueEdited` (protocol/conversation.proto).
    public static let queueCapability = "conversation.v2"
    /// `failure_code` on TaskEnded and TaskSummary, and a follow-up after a failure.
    public static let failuresCapability = "failures.v1"
    /// Agent questions: `QuestionPending`, `AnswerQuestion`, `QuestionResolved` (protocol/questions.proto).
    public static let questionsCapability = "questions.v1"
    /// Attachments: UploadBegin / UploadChunk / UploadEnd and `CreateTask.upload_ids` (protocol/attachments.proto).
    public static let attachmentsCapability = "attachments.v1"
}
