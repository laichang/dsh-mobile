import DSHProtocol
import Foundation

/// One dispatcher lives for exactly one socket. Replies and cancellation can only touch its waiters.
package actor FrameDispatcher {
    package enum Failure: Error {
        case disconnected
        case receive(any Error)
    }

    private let transport: any BridgeTransport
    private let onEvent: @Sendable (FrameDispatcher, Dshm_V1_Event) async -> Void
    private let onClose: @Sendable (FrameDispatcher, any Error) async -> Void
    private var writer: OrderedWriter?
    private var reader: Task<Void, Never>?
    private var nextID: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<Dshm_V1_Response, any Error>] = [:]
    private var closeCause: (any Error)?

    package init(transport: any BridgeTransport,
                 onEvent: @escaping @Sendable (FrameDispatcher, Dshm_V1_Event) async -> Void,
                 onClose: @escaping @Sendable (FrameDispatcher, any Error) async -> Void) {
        self.transport = transport
        self.onEvent = onEvent
        self.onClose = onClose
    }

    package func request(_ body: Dshm_V1_Request.OneOf_Body) async throws -> Dshm_V1_Response {
        try Task.checkCancellation()
        if let closeCause { throw closeCause }
        if writer == nil {
            writer = OrderedWriter(transport: transport) { error in await self.close(error) }
            reader = Task { await receive() }
        }
        let id = nextID
        nextID += 1
        var frame = Dshm_V1_Frame()
        frame.request.id = id
        frame.request.body = body
        let bytes: Data = try frame.serializedBytes()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                writer?.send(bytes)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UInt64) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func receive() async {
        do {
            while closeCause == nil {
                let bytes = try await transport.receive()
                guard closeCause == nil else { return }
                let frame = try Dshm_V1_Frame(serializedBytes: bytes)
                switch frame.kind {
                case .response(let response):
                    pending.removeValue(forKey: response.requestID)?.resume(returning: response)
                case .event(let event):
                    // Resumed follows all replay events on the wire. Finish the Core yield before reading it.
                    await onEvent(self, event)
                case .request, nil: break
                }
            }
        } catch {
            await close(Failure.receive(error))
        }
    }

    package func close(_ cause: any Error = Failure.disconnected) async {
        guard closeCause == nil else { return }
        closeCause = cause
        writer?.stop()
        writer = nil
        reader?.cancel()
        reader = nil
        await onClose(self, cause)
        for waiter in pending.values { waiter.resume(throwing: cause) }
        pending.removeAll()
        await transport.close()
    }
}
