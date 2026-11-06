#if DEBUG
import DSHCore
import Foundation
import Testing

@Suite struct DebugEntryPointTests {
    @Test func routesPairDeepLink() throws {
        let url = try #require(URL(string: "dshm://pair?host=192.168.1.5&port=47801&key=abc&secret=s3"))
        #expect(DebugDeepLink.route(url) == .pair(parameters: ["host": "192.168.1.5", "port": "47801", "key": "abc", "secret": "s3"]))
    }

    @Test func ignoresOtherLinks() throws {
        #expect(DebugDeepLink.route(try #require(URL(string: "dshm://other?x=1"))) == nil)
        #expect(DebugDeepLink.route(try #require(URL(string: "https://pair?x=1"))) == nil)
    }

    @Test func parsesLaunchArguments() {
        let o = DebugLaunchOptions.parse(["/app", "-DSHMFakeBridge", "YES", "-DSHMPresetPrompt", "hi there", "-DSHMBridgePort", "47811"])
        #expect(o == .init(useFakeBridge: true, presetPrompt: "hi there", bridgePort: 47811))
        #expect(DebugLaunchOptions.parse(["/app"]) == .init())
    }

    @Test func parsesS2LaunchArguments() {
        let o = DebugLaunchOptions.parse(["/app", "-DSHMFakeBridge", "offline", "-DSHMResetStore", "YES", "-DSHMConnectDelay", "2.5"])
        #expect(o == .init(useFakeBridge: true, fakeBridgeOffline: true, resetStore: true, connectDelay: 2.5))
    }

    @Test func parsesT1FakeHold() {
        let o = DebugLaunchOptions.parse(["/app", "-DSHMFakeBridge", "YES", "-DSHMFakeHold", "Second task"])
        #expect(o == .init(useFakeBridge: true, fakeHold: "Second task"))
    }
}
#endif
