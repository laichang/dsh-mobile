import Foundation
import SwiftData

/// The app's local cache. The host is the source of truth; this is
/// what the app shows while a host is away, and the resume cursor that fills the gap later.

/// One host as last seen, plus its resume cursor: `(logID, lastSeq)` of the host's event log.
@Model
package final class CachedHost {
    @Attribute(.unique) package var key: String
    /// The host's own name from the bridge (e.g. its hostname); the endpoint until first contact.
    package var name: String
    package var logID: String
    /// Last applied `Event.host_seq` of `logID`. Stored as Int64; host seqs stay far below 2^63.
    package var lastSeq: Int64
    package var needsReconciliation = false
    package var lastConnectedAt: Date?

    package init(key: String, name: String) {
        self.key = key
        self.name = name
        self.logID = ""
        self.lastSeq = 0
        self.lastConnectedAt = nil
    }
}

/// One task as last seen: summary, transcript so far, and the per-task chunk cursor.
@Model
package final class CachedTask {
    /// `hostKey` + "\n" + `taskID`: task ids are only unique per host.
    @Attribute(.unique) package var key: String
    package var hostKey: String
    package var taskID: String
    package var title: String
    package var stateRaw: String
    package var message: String
    /// DSH's failure class when the task failed on its model; empty otherwise.
    package var failureCode: String = ""
    package var createdAt: Date
    package var updatedAt: Date
    package var transcript: String
    package var latestReply: String?
    package var sessionRevision: Int64?
    package var externalSession: Bool = false
    package var sessionHistory: Data?
    package var modelSelectionData: Data?
    /// Highest `AssistantChunk.seq` appended to `transcript`, so a replay never appends twice.
    package var lastChunkSeq: Int64
    /// The host log that last touched this task. A task whose log is gone can't make progress.
    package var logID: String
    package var approvalOnly: Bool = false
    package var approvalData: Data = Data()
    /// The task's milestone timeline, a JSON-encoded `MilestoneTimeline`; empty when it has
    /// none. Each `MilestoneAdded` carries the whole todo list, so the card needs only the latest;
    /// the whole timeline is kept for the detail view.
    package var milestonesData: Data = Data()
    /// The session's workspace directory on the host, when the bridge has `drawer.v1`.
    package var workspace: String?
    /// The `updatedAt` the user last saw on the session page. A finished session with a
    /// newer `updatedAt` is "done and not read" (the drawer's blue dot). Local to this phone.
    package var readThrough: Date?
    /// Approvals of this task that were answered (here or on another client), from the
    /// host's `ApprovalResolved` events. The done page says "M 次审批".
    package var approvalsAnswered: Int = 0
    /// The task's thinking and tool-call rows, a JSON-encoded `StructuredTranscript`; empty
    /// when it has none. Each row keeps its place in `transcript` (`TranscriptItem.offset`).
    package var transcriptBlocksData: Data = Data()
    /// When the session's latest turn started, from the bridge (`turn_started_at_ms`); nil
    /// from an older bridge. The done footer's 用时 counts from here.
    package var turnStartedAt: Date?
    /// The follow-ups that wait while the task runs, a JSON-encoded `FollowUpQueue`; empty
    /// when none waits. From the host's `QueuedMessage` events, so a replay rebuilds it.
    package var queueData: Data = Data()
    /// The thumbnail of the photo sent with the first message, a small JPEG; nil without one.
    /// Local to this phone: the host has the photo itself. Read through `sentAttachments`.
    package var photoThumbnail: Data?
    /// The files sent with the first message from this phone, a JSON-encoded
    /// `[MessageAttachment]` with the thumbnails of images; empty without any.
    package var sentAttachmentsData: Data = Data()

    package init(hostKey: String, taskID: String, title: String, createdAt: Date) {
        self.key = Self.key(hostKey: hostKey, taskID: taskID)
        self.hostKey = hostKey
        self.taskID = taskID
        self.title = title
        self.stateRaw = "running"
        self.message = ""
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.transcript = ""
        self.lastChunkSeq = 0
        self.logID = ""
        self.milestonesData = Data()
    }

    package static func key(hostKey: String, taskID: String) -> String { "\(hostKey)\n\(taskID)" }

}
