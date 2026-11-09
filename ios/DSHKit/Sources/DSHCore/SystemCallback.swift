import Foundation

/// Waits for the one answer of a system callback API, such as
/// `SFSpeechRecognizer.requestAuthorization(_:)` (ARCHITECTURE D146).
///
/// Many Objective-C APIs call their handler on a queue of their own, and their handler type is
/// not `@Sendable`. In the app target every declaration is on the main actor by default, so a
/// closure written there for such a handler is a main-actor closure: Swift 6 checks the queue when
/// it runs, and the app stops with `dispatch_assert_queue` on the system's queue. Here the handler
/// is `@Sendable` and belongs to no actor, so it runs on any queue; the caller continues on its
/// own actor after the `await`.
///
///     let status = await SystemCallback.value { SFSpeechRecognizer.requestAuthorization($0) }
public enum SystemCallback {
    public static func value<Value: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        _ call: (@escaping @Sendable (Value) -> Void) -> Void
    ) async -> Value {
        await withCheckedContinuation(isolation: isolation) { (done: CheckedContinuation<Value, Never>) in
            call { done.resume(returning: $0) }
        }
    }
}
