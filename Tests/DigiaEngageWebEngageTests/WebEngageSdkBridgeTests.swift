@testable import DigiaEngage
@testable import DigiaEngageWebEngage
import Foundation
import Testing

/// The bridge's own state: the pre-register hold, the per-experiment gate, and
/// private-selector safety.
///
/// This delegate is installed in `AppDelegate`, strictly earlier than any plugin
/// can register, so WebEngage can prepare a campaign before `Digia.register`.
/// That campaign is suppressed — WebEngage renders nothing — and held, gate kept,
/// until the plugin registers and Digia is ready, as on Android.
///
/// Every method involved is pure plugin state, so no WebEngage instance is needed.
@Suite("WebEngageSdkBridge", .serialized)
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

    @MainActor
    @Test("a payload prepared before register is held, then delivered once registered and ready")
    func holdsBeforeRegister() {
        // WebEngage calls back on the main thread; the hold relies on it.
        let bridge = makeBridge()
        let suppressed = prepare(bridge, experimentId: "exp_early")
        #expect(suppressed, "WebEngage must not render under a Digia claim, even with no plugin registered")

        let config = WebEngagePluginConfig(diagnosticsEnabled: false)
        let plugin = DigiaWebEngagePlugin(
            bridge: bridge,
            mapper: WebEngagePayloadMapper(config: config),
            config: config,
            cache: InAppDataCache()
        )
        let host = FakeCEPHost()
        host.isReady = false
        plugin.attach(host: host)
        #expect(host.delivered.isEmpty, "Digia is not ready yet: still held")

        host.isReady = true
        plugin.onHostReady()
        #expect(host.delivered.map(\.cepCampaignId) == ["exp_early"])
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

    @Test("a WebEngage-side dismissal frees the gate at once")
    func webEngageDismissalFreesGateAtOnce() {
        // No `notification_close` is sent on this path, so there is no echo
        // to absorb: the free stays immediate.
        let bridge = makeBridge()
        var received: [String] = []
        var invalidated: [String] = []
        bridge.registerInAppListener(
            onPayload: { received.append($0["experimentId"] as? String ?? "") },
            onInvalidate: { invalidated.append($0) }
        )

        prepare(bridge, experimentId: "exp_1")
        bridge.notificationDismissed(["experimentId": "exp_1"])
        prepare(bridge, experimentId: "exp_1")

        #expect(invalidated == ["exp_1"])
        #expect(received == ["exp_1", "exp_1"])
    }

    @Test("the gate stays shut through the close-echo window, then reopens")
    func gateHoldsThroughEchoWindow() {
        // Device proof: the `notification_close` echo re-prepares the same
        // experiment within ~330 ms of the outcome. The gate must still be
        // set then, and free after the window, or the survey loops forever.
        let bridge = makeBridge()
        var pending: [() -> Void] = []
        bridge.schedule = { _, work in pending.append(work) }
        var received: [String] = []
        bridge.registerInAppListener(
            onPayload: { received.append($0["experimentId"] as? String ?? "") },
            onInvalidate: { _ in }
        )

        prepare(bridge, experimentId: "exp_1")
        bridge.notifyDismissed(experimentId: "exp_1")
        prepare(bridge, experimentId: "exp_1")

        #expect(received == ["exp_1"], "the echo inside the window stays blocked")

        for work in pending { work() }
        prepare(bridge, experimentId: "exp_1")

        #expect(received == ["exp_1", "exp_1"], "after the window the campaign can come back")
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
