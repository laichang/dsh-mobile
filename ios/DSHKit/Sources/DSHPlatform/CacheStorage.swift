import Foundation
import SwiftData

package struct CacheStorage {
    /// The cache on disk; if it can't be opened (e.g. an incompatible schema in a dev build),
    /// start from an empty one rather than not at all. The host is the source of truth.
    package static func onDevice() -> CacheStorage {
        if let container = try? Self() { return container }
        let url = URL.applicationSupportDirectory.appending(path: "default.store")
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(filePath: url.path() + suffix))
        }
        if let container = try? Self() { return container }
        return try! Self(inMemory: true)
    }

    @MainActor
    package func erase() throws { try Self.erase(storage) }

    private let storage: ModelContainer

    package init(url: URL? = nil, inMemory: Bool = false) throws {
        storage = try Self.container(url: url, inMemory: inMemory)
    }

    @MainActor
    package func session(hostKey: String, name: String) -> HostStorage {
        HostStorage(container: storage, key: hostKey, name: name)
    }

    private static let models: [any PersistentModel.Type] = [CachedHost.self, CachedTask.self]

    /// The app's store on disk, or at `url` (tests), or in memory.
    private static func container(url: URL? = nil, inMemory: Bool = false) throws -> ModelContainer {
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
    private static func erase(_ container: ModelContainer) throws {
        let context = ModelContext(container)
        try context.delete(model: CachedTask.self)
        try context.delete(model: CachedHost.self)
        try context.save()
    }
}

@MainActor
package final class HostStorage {
    private let context: ModelContext
    package let host: CachedHost

    fileprivate init(container: ModelContainer, key: String, name: String) {
        context = ModelContext(container)
        context.autosaveEnabled = false
        let descriptor = FetchDescriptor<CachedHost>(predicate: #Predicate { $0.key == key })
        if let existing = try? context.fetch(descriptor).first {
            host = existing
        } else {
            host = CachedHost(key: key, name: name)
            context.insert(host)
        }
    }

    package func tasks() -> [CachedTask] {
        let key = host.key
        return (try? context.fetch(FetchDescriptor<CachedTask>(predicate: #Predicate { $0.hostKey == key }))) ?? []
    }

    package func task(key: String) -> CachedTask? {
        let hostKey = host.key
        return try? context.fetch(FetchDescriptor<CachedTask>(predicate: #Predicate { $0.hostKey == hostKey && $0.key == key })).first
    }

    package func insert(_ task: CachedTask) { context.insert(task) }
    package func delete(_ task: CachedTask) { context.delete(task) }

    package func flush(beforeSave: () throws -> Void = {}) throws {
        guard context.hasChanges else { return }
        try beforeSave()
        try context.save()
    }
}
