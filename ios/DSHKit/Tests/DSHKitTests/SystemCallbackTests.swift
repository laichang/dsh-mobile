import DSHCore
import Foundation
import SystemCallbackDoubles
import Testing

/// The mic key crashed on a real iPhone: the speech permission handler was a closure
/// written on the main actor, and the Speech framework called it on its own queue, where Swift 6
/// stops the app (`dispatch_assert_queue`). `DSHBackgroundAuthorizer` is an Objective-C API of
/// the same shape (handler not `NS_SWIFT_SENDABLE`, called on a global queue). Through
/// `SystemCallback.value` its answer reaches a main-actor caller. The old shape,
///
///     await withCheckedContinuation { done in
///         DSHBackgroundAuthorizer.requestAuthorization { done.resume(returning: $0) }
///     }
///
/// in this main-actor suite stops the test process with signal 4 (checked on 2026-11-09).
@MainActor
@Suite struct SystemCallbackTests {
    @Test func anAnswerOnTheSystemsQueueReachesAMainActorCaller() async {
        let status = await SystemCallback.value { DSHBackgroundAuthorizer.requestAuthorization($0) }
        #expect(status == 3, "the handler ran off the main queue (-1: on it)")
        MainActor.assertIsolated("the caller continues on the main actor")
    }

    @Test func manyAnswersInARow() async {
        var statuses: [Int] = []
        for _ in 0..<20 { statuses.append(await SystemCallback.value { DSHBackgroundAuthorizer.requestAuthorization($0) }) }
        #expect(statuses == Array(repeating: 3, count: 20))
    }
}
