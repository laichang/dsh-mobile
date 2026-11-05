import Foundation
import SwiftData

/// S2 · the app's local cache (ARCHITECTURE D9, D20). The host is the source of truth; this is
/// what the app shows while a host is away, and the resume cursor that fills the gap later.

/// One host as last seen, plus its resume cursor: `(logID, lastSeq)` of the host's event log.
@Model
public final class CachedHost {
    @Attribute(.unique) public var key: String
    /// The host's own name from the bridge (e.g. its hostname); the endpoint until first contact.
    public var name: String
    public var logID: String
    /// Last applied `Event.host_seq` of `logID`. Stored as Int64; host seqs stay far below 2^63.
    public var lastSeq: Int64
    public var lastConnectedAt: Date?

    public init(key: String, name: String) {
        self.key = key
        self.name = name
        self.logID = ""
        self.lastSeq = 0
        self.lastConnectedAt = nil
    }
}

/// One task as last seen: summary, transcript so far, and the per-task chunk cursor.
@Model
public final class CachedTask {
    /// `hostKey` + "\n" + `taskID`: task ids are only unique per host.
    @Attribute(.unique) public var key: String
    public var hostKey: String
    public var taskID: String
    public var title: String
    public var stateRaw: String
    public var message: String
    public var createdAt: Date
    public var updatedAt: Date
    public var transcript: String
    /// Highest `AssistantChunk.seq` appended to `transcript`, so a replay never appends twice.
    public var lastChunkSeq: Int64
    /// The host log that last touched this task. A task whose log is gone can't make progress.
    public var logID: String

    public init(hostKey: String, taskID: String, title: String, createdAt: Date) {
        self.key = Self.key(hostKey: hostKey, taskID: taskID)
        self.hostKey = hostKey
        self.taskID = taskID
        self.title = title
        self.stateRaw = TaskState.running.rawValue
        self.message = ""
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.transcript = ""
        self.lastChunkSeq = 0
        self.logID = ""
    }

    public var state: TaskState {
        get { TaskState(rawValue: stateRaw) ?? .running }
        set { stateRaw = newValue.rawValue }
    }

    public static func key(hostKey: String, taskID: String) -> String { "\(hostKey)\n\(taskID)" }
}

public enum TaskCache {
    public static let models: [any PersistentModel.Type] = [CachedHost.self, CachedTask.self]

    /// The app's store on disk, or at `url` (tests), or in memory.
    public static func container(url: URL? = nil, inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(models)
        let config = if let url {
            ModelConfiguration(schema: schema, url: url)
        } else {
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        }
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// Deletes every cached host and task (debug `-DSHMResetStore`).
    @MainActor
    public static func erase(_ container: ModelContainer) throws {
        let context = ModelContext(container)
        try context.delete(model: CachedTask.self)
        try context.delete(model: CachedHost.self)
        try context.save()
    }
}
