import Observation
import Synchronization
import Testing

/// Waits until `condition` is true, with no polling and no fixed sleep (#26). `condition`
/// must read only `@Observable` state (`TaskStore`, `TaskListStore`): it runs again only after one
/// of the properties it read changes. The deadline is generous, so a busy machine makes a test
/// slower, not red. A sleep loop with a short timeout failed under load (load average 75–190).
@MainActor
func waitForStore(_ what: String, timeout: Duration = .seconds(30),
                  sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while true {
        let wake = Wake()
        if withObservationTracking(condition, onChange: { wake.fire() }) { return }
        if ContinuousClock.now >= deadline {
            Issue.record("timed out after \(timeout): \(what)", sourceLocation: sourceLocation)
            return
        }
        let timer = Task { try? await Task.sleep(until: deadline); wake.fire() }
        await wake.wait()
        timer.cancel()
    }
}

/// A one-shot signal: `wait()` returns once `fire()` was called, before or after it.
final class Wake: Sendable {
    private let state = Mutex<(fired: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))

    func fire() {
        let waiter = state.withLock { s -> CheckedContinuation<Void, Never>? in
            guard !s.fired else { return nil }
            s.fired = true
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let firedAlready = state.withLock { s in
                if s.fired { return true }
                s.waiter = c
                return false
            }
            if firedAlready { c.resume() }
        }
    }
}
