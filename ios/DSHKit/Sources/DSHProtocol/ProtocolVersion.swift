/// Constants for protocol/frame.proto. Generated message types live in Generated/ (scripts/codegen).
public enum DSHProtocolInfo {
    /// Sent in `Hello.protocol_version`. Must match the bridge's PROTOCOL_VERSION.
    public static let version: UInt32 = 1
    /// Capability the bridge advertises for T0's CreateTask / AssistantChunk / TaskEnded.
    public static let tasksCapability = "tasks.v1"
    /// S3: the bridge sends `MilestoneAdded` events (protocol/milestones.proto).
    public static let milestonesCapability = "milestones.v1"
    public static let interruptCapability = "interrupt.v1"
    /// S2: ListTasks, Resume and `Event.host_seq` (protocol/s2.proto).
    public static let resumeCapability = "resume.v1"
}
