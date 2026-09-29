@testable import DigiaEngageWebEngage
import Foundation
import Testing

/// The pre-attach drop.
///
/// This delegate is installed in `AppDelegate`, strictly earlier than any plugin
/// can attach, so WebEngage can prepare a campaign while `Digia.initialize()` is
/// still in flight. That campaign is suppressed — WebEngage renders nothing —
/// then dropped at once as not_ready, with its gate and cache freed so nothing
/// is silenced for the session. No wait, no grey modal, no close reported.
///
/// Only the drop is exercised here — every method involved is pure plugin
/// state, so no WebEngage instance is needed.
@Suite("WebEngageSdkBridge — pre-attach drop", .serialized)
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

    @Test("a payload prepared before attach is suppressed and dropped at once")
    func dropsBeforeAttach() {
        let bridge = makeBridge()
        let suppressed = prepare(bridge, experimentId: "exp_early")

        #expect(suppressed, "WebEngage must not render under a Digia claim, even with no plugin attached")

        var received: [String] = []
        bridge.registerInAppListener(
            onPayload: { received.append($0["experimentId"] as? String ?? "") },
            onInvalidate: { _ in }
        )

        #expect(received.isEmpty, "no wait, no flush — the pre-attach payload is gone")

        // The drop freed the gate, so the campaign can come back.
        prepare(bridge, experimentId: "exp_early")
        #expect(received == ["exp_early"])
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

    @Test("every pre-attach drop frees its gate, so nothing is silenced for the session")
    func preAttachDropsFreeGates() {
        let bridge = makeBridge()
        for index in 1...6 {
            let suppressed = prepare(bridge, experimentId: "exp_\(index)")
            #expect(suppressed)
        }

        var received: [String] = []
        bridge.registerInAppListener(
            onPayload: { received.append($0["experimentId"] as? String ?? "") },
            onInvalidate: { _ in }
        )

        #expect(received.isEmpty, "nothing was buffered, so nothing flushes")

        prepare(bridge, experimentId: "exp_1")
        #expect(received == ["exp_1"], "the drop freed the gate: the same experiment can come back")
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
