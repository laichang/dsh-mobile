#if DEBUG
import DSHTestSupport
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
        let o = DebugLaunchOptions.parse(["/app", "-DSHMFakeBridge", "YES", "-DSHMPresetPrompt", "hi there"])
        #expect(o == .init(useFakeBridge: true, presetPrompt: "hi there"))
        #expect(DebugLaunchOptions.parse(["/app"]) == .init())
    }

    @Test func parsesDurableListLaunchArguments() {
        let o = DebugLaunchOptions.parse(["/app", "-DSHMFakeBridge", "offline", "-DSHMResetStore", "YES", "-DSHMConnectDelay", "2.5"])
        #expect(o == .init(useFakeBridge: true, fakeBridgeOffline: true, resetStore: true, connectDelay: 2.5))
    }

    @Test func parsesFakeHold() {
        let o = DebugLaunchOptions.parse(["/app", "-DSHMFakeBridge", "YES", "-DSHMFakeHold", "Second task"])
        #expect(o == .init(useFakeBridge: true, fakeHold: "Second task"))
    }

    @Test func liveActivitiesOnlyWhenATestLaunchAsks() {
        #expect(DebugLaunchOptions.liveActivitiesOn(["/app"]))
        #expect(DebugLaunchOptions.liveActivitiesOn(["/app", "-AppleLanguages", "(en)"]))
        #expect(!DebugLaunchOptions.liveActivitiesOn(["/app", "-DSHMFakeBridge", "YES"]))
        #expect(DebugLaunchOptions.liveActivitiesOn(["/app", "-DSHMFakeBridge", "YES", "-DSHMLiveActivityProbe", "YES"]))
        #expect(!DebugLaunchOptions.liveActivitiesOn(["/app", "-DSHMLiveActivityProbe", "NO"]))
    }

    @Test func parsesUIKitAnimationsSwitch() {
        #expect(DebugLaunchOptions.parse(["/app"]).uikitAnimations)
        #expect(!DebugLaunchOptions.parse(["/app", "-DSHMUIKitAnimations", "NO"]).uikitAnimations)
        #expect(DebugLaunchOptions.parse(["/app", "-DSHMUIKitAnimations", "YES"]).uikitAnimations)
    }
}
#endif
