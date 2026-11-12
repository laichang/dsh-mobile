import DSHPlatform
import Foundation

extension CachedTask {
    var history: SessionHistory? { sessionHistory.flatMap { try? SessionHistory(cacheData: $0) } }
    /// The first message's attachments as this phone sent them; a cache from before files of any type has only
    /// `photoThumbnail`.
    var sentAttachments: [MessageAttachment] {
        get {
            if !sentAttachmentsData.isEmpty,
               let list = try? JSONDecoder().decode([MessageAttachment].self, from: sentAttachmentsData) { return list }
            return photoThumbnail.map { [MessageAttachment(kind: .image, name: "photo.jpg", size: 0, mediaType: "image/jpeg", thumbnail: $0)] } ?? []
        }
        set { sentAttachmentsData = newValue.isEmpty ? Data() : (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var state: TaskState {
        get { TaskState(rawValue: stateRaw) ?? .running }
        set { stateRaw = newValue.rawValue }
    }

    var approvals: [Approval] {
        get { (try? JSONDecoder().decode([Approval].self, from: approvalData)) ?? [] }
        set { approvalData = newValue.isEmpty ? Data() : (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var milestones: MilestoneTimeline {
        get {
            guard !milestonesData.isEmpty else { return MilestoneTimeline() }
            return (try? JSONDecoder().decode(MilestoneTimeline.self, from: milestonesData)) ?? MilestoneTimeline()
        }
        set { milestonesData = newValue.isEmpty ? Data() : (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var structuredTranscript: StructuredTranscript {
        get {
            guard !transcriptBlocksData.isEmpty else { return StructuredTranscript() }
            return (try? JSONDecoder().decode(StructuredTranscript.self, from: transcriptBlocksData)) ?? StructuredTranscript()
        }
        set { transcriptBlocksData = newValue.isEmpty ? Data() : (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var followUpQueue: FollowUpQueue {
        get {
            guard !queueData.isEmpty else { return FollowUpQueue() }
            return (try? JSONDecoder().decode(FollowUpQueue.self, from: queueData)) ?? FollowUpQueue()
        }
        set { queueData = newValue.isEmpty ? Data() : (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}


public struct TaskCache {
    let storage: CacheStorage

    public init(url: URL? = nil, inMemory: Bool = false) throws {
        storage = try CacheStorage(url: url, inMemory: inMemory)
    }

    private init(storage: CacheStorage) { self.storage = storage }

    public static func onDevice() -> Self { Self(storage: .onDevice()) }

    @MainActor public func erase() throws { try storage.erase() }
}
