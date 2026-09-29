@testable import DigiaEngageWebEngage
import Foundation
import Testing

/// The WE-14 screen hold.
///
/// WebEngage iOS drops an in-flight in-app render on a screen change. The bridge
/// holds each screen change until that render reaches `notificationPrepared`,
/// capped at 1 s. A manual scheduler replaces the main queue, so no WebEngage
/// instance and no real waiting is needed.
@Suite("WebEngageSdkBridge — screen hold", .serialized)
struct WebEngageScreenHoldTests {

    /// Runs scheduled work only when the test says so, earliest first.
    private final class ManualScheduler {
        private var now: TimeInterval = 0
        private var queue: [(at: TimeInterval, work: () -> Void)] = []

        func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
            queue.append((now + delay, work))
        }

        func advance(by interval: TimeInterval) {
            let end = now + interval
            while let index = queue.indices.filter({ queue[$0].at <= end })
                .min(by: { queue[$0].at < queue[$1].at }) {
                let item = queue.remove(at: index)
                now = item.at
                item.work()
            }
            now = end
        }
    }

    private let scheduler = ManualScheduler()
    private let bridge = WebEngageSdkBridge(config: WebEngagePluginConfig(diagnosticsEnabled: false))
    private var forwarded: [String] { forwardedBox.names }
    private let forwardedBox = Box()

    private final class Box { var names: [String] = [] }

    init() {
        let scheduler = scheduler
        let box = forwardedBox
        bridge.schedule = { scheduler.schedule($0, $1) }
        bridge.forwardScreen = { box.names.append($0) }
        bridge.renderingNotificationId = { nil }
    }

    private func prepare(experimentId: String) {
        var stop = ObjCBool(false)
        _ = withUnsafeMutablePointer(to: &stop) { pointer in
            bridge.notificationPrepared(["experimentId": experimentId], shouldStop: pointer)
        }
    }

    @Test("with no render in flight, the screen goes out after the start window")
    func forwardsWhenIdle() {
        bridge.navigateScreen("Cart")
        scheduler.advance(by: 0.05)
        #expect(forwarded.isEmpty)

        scheduler.advance(by: 0.06)
        #expect(forwarded == ["Cart"])
    }

    @Test("a render in flight holds the screen until notificationPrepared")
    func holdsUntilPrepared() {
        bridge.renderingNotificationId = { "exp_1" }
        bridge.navigateScreen("Cart")
        scheduler.advance(by: 0.5)
        #expect(forwarded.isEmpty, "WebEngage would drop the render on this screen change")

        prepare(experimentId: "exp_1")
        scheduler.advance(by: 0)
        #expect(forwarded == ["Cart"])
    }

    @Test("a render that never settles releases the screen after 1 s")
    func releasesAfterTimeout() {
        bridge.renderingNotificationId = { "exp_1" }
        bridge.navigateScreen("Cart")
        scheduler.advance(by: 1.05)
        #expect(forwarded.isEmpty)

        scheduler.advance(by: 0.1)
        #expect(forwarded == ["Cart"])
    }

    @Test("a render that already reached the callback does not hold")
    func settledRenderDoesNotHold() {
        prepare(experimentId: "exp_1")
        bridge.renderingNotificationId = { "exp_1" }
        bridge.navigateScreen("Cart")
        scheduler.advance(by: 0.11)
        #expect(forwarded == ["Cart"])
    }

    @Test("screen changes keep their order while one is held")
    func keepsOrder() {
        bridge.renderingNotificationId = { "exp_1" }
        bridge.navigateScreen("Cart")
        bridge.navigateScreen("Checkout")
        scheduler.advance(by: 0.2)

        prepare(experimentId: "exp_1")
        scheduler.advance(by: 0.2)
        #expect(forwarded == ["Cart", "Checkout"])
    }

    @Test("a missing rendering selector reads as not rendering, not a crash")
    func missingRenderingSelector() {
        #expect(bridge.boolPrivate(NSObject(), NSSelectorFromString("rendering")) == false)
    }
}
