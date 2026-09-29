@testable import DigiaEngageWebEngage
import Foundation
import Testing

/// The pre-attach buffer.
///
/// This delegate is installed in `AppDelegate`, strictly earlier than any plugin
/// can attach, so WebEngage can prepare a campaign while `Digia.initialize()` is
/// still in flight. Suppressing that campaign sets its gate; if the payload is
/// simply dropped, the gate is never cleared and WebEngage will not offer the
/// campaign again for the rest of the session. Buffering preserves the
/// app-launch campaign; bounding the buffer is what stops a misconfigured app
/// from accumulating every campaign it ever suppressed.
///
/// Only the buffer is exercised here — every method involved is pure plugin
/// state, so no WebEngage instance is needed.
@Suite("WebEngageSdkBridge — pre-attach buffer", .serialized)
struct WebEngageSdkBridgeTests {

    private func makeBridge() -> WebEngageSdkBridge {
        WebEngageSdkBridge(config: WebEngagePluginConfig(diagnosticsEnabled: false))
    }

    /// Returns whether WebEngage's own renderer was suppressed.
    @discardableResult
    private func prepare(
        _ bridge: WebEngageSdkBridge,
        experimentId: String,
        payload: [String: Any]? = nil
    ) -> Bool {
        var stop = ObjCBool(false)
        _ = withUnsafeMutablePointer(to: &stop) { pointer in
            bridge.notificationPrepared(
                payload ?? ["experimentId": experimentId, "digiaKey": "onboarding_tip"],
                shouldStop: pointer
            )
        }
        return stop.boolValue
    }

    @Test("a payload prepared before attach is flushed when the plugin attaches")
    func flushesOnAttach() {
        let bridge = makeBridge()
        prepare(bridge, experimentId: "exp_early")

        var received: [String] = []
        bridge.registerInAppListener(
            onPayload: { received.append($0["experimentId"] as? String ?? "") },
            onInvalidate: { _ in }
        )

        #expect(received == ["exp_early"], "an app-launch campaign must survive the registration gap")
    }

    @Test("unregister then register again keeps interception working")
    func reregisterKeepsInterception() {
        // A second register must not end interception.
        let bridge = makeBridge()
        var first: [String] = []
        bridge.registerInAppListener(
            onPayload: { first.append($0["experimentId"] as? String ?? "") },
            onInvalidate: { _ in }
        )
        bridge.unregisterInAppListener()

        var second: [String] = []
        bridge.registerInAppListener(
            onPayload: { second.append($0["experimentId"] as? String ?? "") },
            onInvalidate: { _ in }
        )
        prepare(bridge, experimentId: "exp_1")

        #expect(first.isEmpty)
        #expect(second == ["exp_1"])
    }

    @Test("the buffer is bounded, and evicting releases the gate it drops")
    func bufferIsBounded() {
        let bridge = makeBridge()
        // One more than the cap, so the oldest is evicted.
        for index in 1...6 { prepare(bridge, experimentId: "exp_\(index)") }

        var received: [String] = []
        bridge.registerInAppListener(
            onPayload: { received.append($0["experimentId"] as? String ?? "") },
            onInvalidate: { _ in }
        )

        #expect(received == ["exp_2", "exp_3", "exp_4", "exp_5", "exp_6"], "bounded at 5, oldest first out")

        // The evicted one released its gate, so WebEngage can offer it again —
        // losing the campaign is survivable, silencing it for the session is not.
        prepare(bridge, experimentId: "exp_1")
        #expect(received.last == "exp_1")
    }

    @Test("a duplicate preparation for a live experiment is blocked")
    func duplicatePreparationBlocked() {
        let bridge = makeBridge()
        var received: [String] = []
        bridge.registerInAppListener(
            onPayload: { received.append($0["experimentId"] as? String ?? "") },
            onInvalidate: { _ in }
        )

        prepare(bridge, experimentId: "exp_1")
        prepare(bridge, experimentId: "exp_1")

        #expect(received == ["exp_1"], "the gate is what stops WebEngage rendering it twice")
    }

    @Test("releasing the gate lets the campaign be prepared again")
    func releasedGateAllowsRetrigger() {
        let bridge = makeBridge()
        var received: [String] = []
        bridge.registerInAppListener(
            onPayload: { received.append($0["experimentId"] as? String ?? "") },
            onInvalidate: { _ in }
        )

        prepare(bridge, experimentId: "exp_1")
        bridge.releaseGate(experimentId: "exp_1")
        prepare(bridge, experimentId: "exp_1")

        #expect(received == ["exp_1", "exp_1"])
    }

    @Test("a campaign claimed by a keyless digia-config block is suppressed but holds nothing")
    func keylessBlockHoldsNoGate() {
        // The gate deliberately claims a `<template id="digia-config">` block whether or not
        // the marketer put a campaign key in it, so the mapper can refuse a campaign the
        // bridge already suppressed. Nothing will ever settle a presentation that was never
        // delivered — so if this took the per-experiment gate, that experiment would be
        // silenced for the rest of the session with no way back.
        let bridge = makeBridge()
        var received: [String] = []
        bridge.registerInAppListener(
            onPayload: { received.append($0["experimentId"] as? String ?? "") },
            onInvalidate: { _ in }
        )

        let suppressed = prepare(
            bridge,
            experimentId: "exp_1",
            payload: [
                "experimentId": "exp_1",
                "html": #"<template id="digia-config"><meta name="tier" content="gold"></template>"#,
            ])

        #expect(suppressed, "a block is unambiguously ours — WebEngage must not render under it")
        #expect(received.isEmpty, "and the mapper cannot map it, so nothing is delivered")

        prepare(bridge, experimentId: "exp_1")
        #expect(received == ["exp_1"], "the gate was never taken: the same experiment can come back")
    }

    @Test("a missing private selector is skipped, not raised")
    func missingPrivateSelectorSkips() {
        // A WebEngage upgrade that renames a private symbol must not
        // crash the host app. A bare NSObject implements nothing here.
        let bridge = makeBridge()
        let target = NSObject()
        let missing = NSSelectorFromString("trackSDKEventWithName:andValue:")

        #expect(bridge.valuePrivate(target, missing) == nil)
        #expect(bridge.callPrivate(target, missing, "x" as NSString, [:] as NSDictionary) == false)
    }

    @Test("a present selector still goes through")
    func presentSelectorStillCalls() {
        let bridge = makeBridge()
        let target = NSObject()

        let value = bridge.valuePrivate(target, NSSelectorFromString("description"))
        #expect((value as? String)?.isEmpty == false)
    }
}
