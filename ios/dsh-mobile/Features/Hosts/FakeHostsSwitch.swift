#if DEBUG
import CoreFoundation
import DSHTestSupport
import Synchronization

/// S21 · stops and starts the `FakeHosts` of `-DSHMFakeBridge hosts…` from a UI test. Debug only.
///
/// A UI test posts the Darwin notification `FakeHosts.hostsDown` (every host that can be
/// reached becomes unreachable, as when the phone leaves the Wi-Fi) or `FakeHosts.hostsUp`
/// (MacBook-Pro is back), or `FakeHosts.hostsRevoke` (S29: another client revokes this phone
/// on MacBook-Pro). After `hostsUp` the app retries at once (`wake`), as it does on
/// foreground, instead of after its backoff.
enum FakeHostsSwitch {
    private static let hosts = Mutex<[FakeHost]>([])
    private static let wake = Mutex<(@Sendable () -> Void)?>(nil)
    private static let observing = Mutex(false)

    static func watch(_ switchable: [FakeHost], wake: @escaping @Sendable () -> Void) {
        hosts.withLock { $0 = switchable }
        self.wake.withLock { $0 = wake }
        let first = observing.withLock { observing in
            defer { observing = true }
            return !observing
        }
        guard first else { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for name in [FakeHosts.hostsDown, FakeHosts.hostsUp] {
            CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                FakeHostsSwitch.set(up: name?.rawValue as String? == FakeHosts.hostsUp)
            }, name as CFString, nil, .deliverImmediately)
        }
        // S29: MacBook-Pro closes this phone's sockets with 4003 and refuses it from now on.
        CFNotificationCenterAddObserver(center, nil, { _, _, _, _, _ in
            FakeHostsSwitch.hosts.withLock { $0 }.first?.revokeThisDevice()
        }, FakeHosts.hostsRevoke as CFString, nil, .deliverImmediately)
    }

    private static func set(up: Bool) {
        let switchable = hosts.withLock { $0 }
        if up {
            switchable.first?.setReachable(true)
            wake.withLock { $0 }?()
        } else {
            for host in switchable { host.setReachable(false) }
        }
    }
}
#endif
