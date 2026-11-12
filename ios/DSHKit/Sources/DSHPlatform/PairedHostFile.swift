import Foundation
import Synchronization

// Independent store instances may update the same file.
private let writers = Mutex(())

package struct PairedHostFile<Record: Codable & Equatable>: Sendable {
    package let url: URL

    package init(url: URL?) {
        self.url = url ?? URL.applicationSupportDirectory.appending(path: "paired-hosts.json")
    }

    package func read() throws -> [Record] {
        do {
            return try JSONDecoder().decode([Record].self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
    }

    @discardableResult
    package func mutate<Result>(_ body: (inout [Record]) -> Result) throws -> Result {
        try writers.withLock { _ in
            let before = try read()
            var after = before
            let result = body(&after)
            if before != after {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(after).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            return result
        }
    }
}
