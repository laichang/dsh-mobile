import Foundation

/// Enqueue sealed messages synchronously so actor suspension cannot reorder cipher nonces.
package struct OrderedWriter: Sendable {
    private let queue: AsyncStream<Data>.Continuation
    private let worker: Task<Void, Never>

    package init(transport: any BridgeTransport, onFailure: @escaping @Sendable (any Error) async -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        queue = continuation
        worker = Task {
            do {
                for await bytes in stream {
                    try Task.checkCancellation()
                    try await transport.send(bytes)
                }
            } catch {
                if !Task.isCancelled { await onFailure(error) }
            }
        }
    }

    package func send(_ bytes: Data) { queue.yield(bytes) }

    package func stop() {
        worker.cancel()
        queue.finish()
    }
}
