@testable import DigiaEngage
@testable import DigiaEngageWebEngage
import Foundation
import Testing

@MainActor
private final class Harness {
    let bridge: FakeWebEngageBridge
    let host: FakeCEPHost
    let plugin: DigiaWebEngagePlugin

    init(host: FakeCEPHost = FakeCEPHost(), attach: Bool = true) {
        let config = WebEngagePluginConfig(diagnosticsEnabled: false)
        self.bridge = FakeWebEngageBridge()
        self.host = host
        self.plugin = DigiaWebEngagePlugin(
            bridge: bridge,
            mapper: WebEngagePayloadMapper(config: config),
            config: config,
            cache: InAppDataCache()
        )
        if attach { plugin.attach(host: host) }
    }

    var core: PresentationController { host.last }
}

/// Lifecycle tests for WebEngage's per-experiment gate.
///
/// WebEngage has no visual slot; what it has is a gate that stops it preparing
/// the same campaign twice, set the moment Digia suppresses WebEngage's own
/// renderer. Because a suppressed notification never reaches WebEngage's dismiss
/// callback, only the plugin can clear it — so every test here is asking the
/// same question: **was the gate released?** The second question is whether
/// `notification_close` was reported honestly, because a close booked against an
/// impression that never happened cannot be unsent.
@MainActor
@Suite("DigiaWebEngagePlugin — gate lifecycle", .serialized)
struct DigiaWebEngagePluginTests {

    // MARK: - The gate: released on both arms, always

    @Test("releases the gate when the experience is dismissed")
    func releasesGateOnDismiss() async {
        let h = Harness()
        h.bridge.emitPrepared(inAppPayload())

        h.core.markDisplaying()
        h.core.settle(.dismissed(reason: .userClose, completed: false))
        await drainMainActor()

        #expect(h.bridge.releasedGates == ["exp_1"])
        #expect(h.bridge.delayedGateReleases == ["exp_1"], "the outcome path must ride the echo window, not free the gate at once")
    }

    @Test("releases the gate when the campaign is dropped")
    func releasesGateOnDrop() async {
        let h = Harness()
        h.bridge.emitPrepared(inAppPayload())

        h.core.settle(.dropped(reason: .screenNotTargeted, detail: nil))
        await drainMainActor()

        #expect(h.bridge.releasedGates == ["exp_1"], "a drop must free the gate exactly like a dismissal")
    }

    @Test("a synchronous drop releases the gate without waiting for a task")
    func syncDropReleasesGateInline() {
        // No `await` anywhere: deliver() returns already settled, so a plugin
        // that only bound to a task would leave the gate set across a suspension.
        let h = Harness(host: FakeCEPHost(syncDrop: .frequencyCapped))

        h.bridge.emitPrepared(inAppPayload())

        #expect(h.host.delivered.count == 1, "Digia must actually have been asked")
        #expect(h.bridge.releasedGates == ["exp_1"])
    }

    @Test("detach releases the gate for a live presentation")
    func detachReleasesGate() {
        let h = Harness()
        h.bridge.emitPrepared(inAppPayload())
        h.core.markDisplaying()

        h.plugin.detach()

        #expect(h.bridge.releasedGates == ["exp_1"], "unregistering must not silence the campaign for the session")
        #expect(h.core.isSettled)
        #expect(h.bridge.inAppListenerUnregistered)
    }

    @Test("a WebEngage-side dismissal cancels the presentation and releases the gate")
    func webEngageDismissalCancels() {
        let h = Harness()
        h.bridge.emitPrepared(inAppPayload())
        h.core.markDisplaying()

        h.bridge.emitDismissed(experimentId: "exp_1")

        #expect(h.core.isSettled)
        #expect(h.bridge.releasedGates == ["exp_1"])
        #expect(h.bridge.delayedGateReleases == ["exp_1"], "cancel settles the outcome, so the free rides finish like every other terminal path")
    }

    // MARK: - notification_close: the dismissed arm only

    @Test("reports view then close for an experience that displayed")
    func reportsViewThenClose() async {
        let h = Harness()
        h.bridge.emitPrepared(inAppPayload())

        h.core.markDisplaying()
        #expect(h.bridge.eventNames == ["notification_view"], "no close while it is on screen")

        h.core.settle(.dismissed(reason: .userClose, completed: false))
        await drainMainActor()

        #expect(h.bridge.eventNames == ["notification_view", "notification_close"])
    }

    @Test("reports no close for a campaign that never displayed")
    func noCloseOnDrop() async {
        // The whole point of the two arms. A close here would book a dismissal
        // against an impression WebEngage never recorded, corrupting the
        // experiment's own funnel with no way to unsend it.
        let h = Harness()
        h.bridge.emitPrepared(inAppPayload())

        h.core.settle(.dropped(reason: .unknownCampaignKey, detail: nil))
        await drainMainActor()

        #expect(h.bridge.eventNames.isEmpty)
    }

    @Test("a click reports the CTA it came from")
    func clickReportsCta() {
        let h = Harness()
        h.bridge.emitPrepared(inAppPayload())

        h.core.markDisplaying()
        h.core.emitClicked(elementId: "primary_cta")

        let clicks = h.bridge.eventsNamed("notification_click")
        #expect(clicks.count == 1)
        #expect(clicks.first?.systemData["call_to_action"] as? String == "primary_cta")
    }

    @Test("events carry the experiment and variation WebEngage named")
    func eventsCarryIdentifiers() {
        let h = Harness()
        h.bridge.emitPrepared(inAppPayload(experimentId: "exp_9", variationId: "var_9"))

        h.core.markDisplaying()

        let view = h.bridge.eventsNamed("notification_view").first
        #expect(view?.systemData["experiment_id"] as? String == "exp_9")
        #expect(view?.systemData["id"] as? String == "var_9")
    }

    // MARK: - Wiring

    @Test("screen changes reach WebEngage")
    func screenChangesForwarded() {
        let h = Harness()

        h.plugin.onScreenChanged("Checkout")

        #expect(h.bridge.navigatedScreens == ["Checkout"])
    }

    @Test("a payload arriving with no host attached is dropped, not queued forever")
    func payloadWithoutHost() {
        let h = Harness(attach: false)

        // Nothing is registered, so nothing reaches the plugin at all — a
        // pre-attach payload drops at once in the bridge, and is covered by
        // WebEngageSdkBridgeTests.
        h.bridge.emitPrepared(inAppPayload())

        #expect(h.host.delivered.isEmpty)
    }

    @Test("health reports live presentations and clears after detach")
    func healthReportsLivePresentations() {
        let h = Harness()
        h.bridge.emitPrepared(inAppPayload())

        let live = h.plugin.healthCheck()
        #expect(live.isHealthy)
        #expect(live.metadata["livePresentations"] == "1")

        h.plugin.detach()
        #expect(h.plugin.healthCheck().metadata["livePresentations"] == "0")
        #expect(!h.plugin.healthCheck().isHealthy)
    }
}
