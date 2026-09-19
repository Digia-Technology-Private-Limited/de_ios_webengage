@testable import DigiaEngage
@testable import DigiaEngageWebEngage
import Foundation
import Testing

@MainActor
private final class Harness {
    let bridge: FakeWebEngageBridge
    let host: FakeCEPHost
    let plugin: DigiaWebEngagePlugin

    init(host: FakeCEPHost = FakeCEPHost()) {
        let config = WebEngagePluginConfig(diagnosticsEnabled: false)
        self.bridge = FakeWebEngageBridge()
        self.host = host
        self.plugin = DigiaWebEngagePlugin(
            bridge: bridge,
            mapper: WebEngagePayloadMapper(config: config),
            config: config,
            cache: InAppDataCache()
        )
        plugin.attach(host: host)
    }

    /// Core's write face for the most recent delivery.
    var core: PresentationController { host.last }
}

/// The plugin conformance kit — spec §8.3.
///
/// One scenario table, run against all six plugin targets (Swift × 3,
/// Kotlin × 3). **The test names are the shared vocabulary**: `C4` means the
/// same thing in `ios/moengage` as it does in `android/clevertap`, so a row that
/// is green on five targets and red on one names the divergence by itself.
/// Never rename one without renaming all six.
///
/// "Release" here is WebEngage's **per-experiment gate**. WebEngage has no
/// visual slot; what it has is a mark set the moment Digia suppresses
/// WebEngage's own renderer, which stops it preparing that campaign again. A
/// suppressed notification never reaches WebEngage's dismiss callback, so
/// nothing on WebEngage's side ever clears the mark — only the plugin can, and a
/// mark left set silences that campaign for the rest of the session.
///
/// The gate binds to `outcome`, not to `holdReleased`, and deliberately so: it
/// de-duplicates rather than queues, so freeing it while the experience is still
/// on screen would let WebEngage prepare the same campaign on top of itself.
/// C7 is where that shows.
@MainActor
@Suite("DigiaWebEngagePlugin — CEP conformance (spec §8.3)", .serialized)
struct WebEngageConformanceTests {

    @Test("C1 — deliver then dismissed: exactly one release, after the dismiss")
    func c1DismissedReleasesOnceAfterTheDismiss() async {
        let h = Harness()
        h.bridge.emitPrepared(inAppPayload())

        h.core.markDisplaying()
        #expect(h.bridge.eventNames == ["notification_view"])
        #expect(h.bridge.releasedGates.isEmpty, "the gate is still set while it is on screen")

        h.core.settle(.dismissed(reason: .userClose, completed: false))
        await drainMainActor()

        #expect(h.bridge.releasedGates == ["exp_1"])
        #expect(h.bridge.eventNames == ["notification_view", "notification_close"])
        #expect(h.core.isHoldReleased, "G8: the hold cannot outlive the outcome")
    }

    @Test("C2 — deliver then dropped: exactly one release")
    func c2DroppedReleasesOnce() async {
        let h = Harness()
        h.bridge.emitPrepared(inAppPayload())

        h.core.settle(.dropped(reason: .frequencyCapped, detail: nil))
        await drainMainActor()

        #expect(h.bridge.releasedGates == ["exp_1"], "a drop frees the gate exactly like a dismissal")
        #expect(h.bridge.eventNames.isEmpty, "nothing displayed, so nothing to report")
        #expect(h.core.isHoldReleased)
    }

    @Test("C3 — outcome delayed, then cancel() from the CEP close: one release, idempotent")
    func c3CepCloseCancelsIdempotently() async {
        let h = Harness()
        h.bridge.emitPrepared(inAppPayload())
        h.core.markDisplaying()

        // WebEngage invalidated the campaign while Digia was still displaying it
        // — the CEP-initiated termination, which reaches core as `cancel()`.
        h.bridge.emitDismissed(experimentId: "exp_1")

        #expect(h.bridge.releasedGates == ["exp_1"])
        #expect(h.core.isSettled)
        #expect(
            h.core.presentation.outcome.settledValue == .dismissed(reason: .cancelled, completed: false)
        )

        // G5: `cancel()` is idempotent and safe in any state, settled included.
        h.core.presentation.cancel()
        await drainMainActor()

        #expect(h.bridge.releasedGates == ["exp_1"], "a repeated cancel must not double-release")
    }

    @Test("C4 — plugin unregistered mid-display still releases")
    func c4DetachMidDisplayStillReleases() async {
        // Asserted as a *fact*, not as a code path: after the unregister the
        // CEP's gate is not held, exactly once. That stays true under both
        // designs currently on the table — the iOS `detach()` backstop that
        // releases in-flight presentations, and the pure-G6 form where core
        // settling `plugin_detached` is the only thing that frees it. The two
        // are driven here in the order G6 specifies (settle, then detach) with
        // no drain in between, which is also the race between them.
        let h = Harness()
        h.bridge.emitPrepared(inAppPayload())
        h.core.markDisplaying()

        h.host.settleOwnedPresentations()
        h.plugin.detach()
        await drainMainActor()

        // Recorded while writing this, not fixed here: the iOS backstop calls
        // its terminal funnel with `displayed: false` regardless of what the
        // presentation actually did, so a campaign that *was* on screen loses
        // its final CEP marking when the backstop wins this race. The release
        // itself is never lost, which is why this row asserts the release. See
        // the N3 report.

        #expect(h.bridge.releasedGates == ["exp_1"], "unregistering must free the gate, and free it once")
        #expect(
            h.core.presentation.outcome.settledValue
                == .dismissed(reason: .pluginDetached, completed: false)
        )
    }

    @Test("C5 — a throwing CEP release call is swallowed, with no crash and no lost release")
    func c5MisbehavingReleaseCall() async {
        // platform note: Swift cannot express the Kotlin twin's literal form.
        // `releaseGate(experimentId:)` is non-throwing by type, an Obj-C
        // exception out of WebEngage is not catchable in Swift, and a Swift trap
        // is fatal by design — there is nothing to swallow. iOS is structurally
        // safe for the half the Kotlin fix addressed: `PresentationPromise.settle`
        // resumes continuations and the plugin code awaiting them runs on its own
        // task, so a plugin's completion handler never runs inside core's settle
        // stack and cannot unwind into it.
        //
        // What *is* expressible, and is asserted here, is the rest of the row:
        // the CEP's release call re-enters core from inside the release, and
        // neither the release nor the first outcome is lost — the gate really is
        // free afterwards, which the second delivery proves.
        let h = Harness()
        h.bridge.emitPrepared(inAppPayload())
        h.core.markDisplaying()

        let core = h.core
        h.bridge.onReleaseGate = { _ in
            core.presentation.cancel()
            core.settle(.dropped(reason: .error, detail: "re-entrant settle from the CEP"))
        }

        h.core.settle(.dismissed(reason: .userClose, completed: false))
        await drainMainActor()

        #expect(h.bridge.releasedGates == ["exp_1"])
        #expect(
            core.presentation.outcome.settledValue == .dismissed(reason: .userClose, completed: false),
            "the first outcome stands — G1"
        )

        h.bridge.onReleaseGate = nil
        h.bridge.emitPrepared(inAppPayload())
        #expect(h.host.delivered.count == 2, "the gate was genuinely free afterwards")
    }

    @Test("C6 — re-trigger the same campaignKey while the first is live: two presentations, two releases")
    func c6ReTriggerSameCampaignKey() async {
        // Two WebEngage experiments pointing at one Digia campaign: same
        // `campaignKey` (the viewId), different `cepCampaignId`. The plugin keys
        // its bookkeeping by experiment, so the two must not collide — and
        // identity is `CampaignPresentation.id` regardless, which is what makes
        // the CleverTap form of this collision harmless too.
        let h = Harness()
        h.bridge.emitPrepared(inAppPayload(experimentId: "exp_a", viewId: "promo"))
        h.bridge.emitPrepared(inAppPayload(experimentId: "exp_b", viewId: "promo"))

        #expect(h.host.delivered.count == 2)
        #expect(h.host.delivered.map(\.campaignKey) == ["promo", "promo"])
        #expect(
            h.host.controllers[0].id != h.host.controllers[1].id,
            "two genuinely distinct presentations"
        )

        h.host.controllers[0].markDisplaying()
        h.host.controllers[0].settle(.dismissed(reason: .userClose, completed: false))
        h.host.controllers[1].settle(.dropped(reason: .surfaceBusy, detail: nil))
        await drainMainActor()

        #expect(h.bridge.releasedGates.sorted() == ["exp_a", "exp_b"], "two presentations, two releases")
    }

    @Test("C7 — hold released early: one unblock, clicked still marked, final marking at outcome")
    func c7EarlyHoldRelease() async {
        let h = Harness()
        h.bridge.emitPrepared(inAppPayload())
        h.core.markDisplaying()

        h.core.releaseHold()
        await drainMainActor()

        // The gate is a de-dup gate, not a queue hold, so it deliberately does
        // not move here: freeing it while the experience is still on screen
        // would let WebEngage prepare the same campaign on top of itself. The
        // unblock is the one at `outcome`, below.
        #expect(h.bridge.releasedGates.isEmpty)

        h.core.emitClicked(elementId: "primary_cta")
        #expect(
            h.bridge.eventsNamed("notification_click").count == 1,
            "a click after the hold released is still marked"
        )

        h.core.settle(.dismissed(reason: .screenExit, completed: true))
        await drainMainActor()

        #expect(h.bridge.releasedGates == ["exp_1"], "exactly one unblock, not one per phase")
        #expect(h.bridge.eventsNamed("notification_close").count == 1, "final marking at the outcome")
    }

    @Test("C8 — sync drop with the unblock bound after the fact still fires")
    func c8SyncDropLateAwaiter() async {
        // Regression guard for `PresentationPromise` collapsing back into a
        // fire-and-forget signal. The plugin's own path would survive that — it
        // peeks at the settled outcome before awaiting — so the late awaiter
        // below is the assertion that actually catches it.
        let h = Harness(host: FakeCEPHost(syncDrop: .frequencyCapped))

        h.bridge.emitPrepared(inAppPayload())

        #expect(h.host.delivered.count == 1, "Digia must actually have been asked")
        #expect(h.bridge.releasedGates == ["exp_1"], "released inline, with no turn of the main actor")
        #expect(h.core.isHoldReleased, "G8: the hold settled no later than the outcome")

        let fired = await awaiterAttachedLateFires(h.core.presentation.holdReleased)
        #expect(fired, "a late awaiter must still fire — a missed release wedges the CEP queue")
    }
}
