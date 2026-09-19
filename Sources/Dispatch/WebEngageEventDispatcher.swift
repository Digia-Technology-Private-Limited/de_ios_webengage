import Foundation
import DigiaEngage

/// Translates a presentation's signals and terminal outcome into WebEngage
/// analytics calls. Mirrors `WebEngageEventDispatcher.kt` on Android.
///
/// The v2 split matters here: `notification_view` and `notification_click` are
/// **signals** — best-effort, mid-flight — while `notification_close` rides the
/// terminal path, and only on the arm where the experience actually displayed.
/// A close reported for a campaign that never rendered corrupts WebEngage's
/// own view/close funnel for that experiment, and there is no way to unsend it.
@MainActor
internal final class WebEngageEventDispatcher {

    private let bridge: WebEngageBridgeProtocol
    private let cache: InAppDataCache

    init(bridge: WebEngageBridgeProtocol, cache: InAppDataCache) {
        self.bridge = bridge
        self.cache = cache
    }

    // MARK: - Public

    func forwardScreen(_ name: String) {
        bridge.navigateScreen(name)
    }

    /// The experience became visible.
    ///
    /// Inline content has no close affordance and no terminal moment of its own,
    /// so its view *is* its close — both are reported here and the cache entry
    /// goes with them.
    func notificationViewed(_ payload: CEPTriggerPayload) {
        let ids = identifiers(for: payload)
        bridge.trackSystemEvent(eventName: "notification_view", systemData: ids.systemData, eventData: [:])

        guard isInline(payload) else {
            NSLog("[WebEngageEventDispatcher] dispatched: notification_view experimentId=\(ids.experimentId)")
            return
        }
        bridge.trackSystemEvent(eventName: "notification_close", systemData: ids.systemData, eventData: [:])
        cache.remove(experimentId: ids.experimentId)
        NSLog(
            "[WebEngageEventDispatcher] dispatched: notification_view + notification_close (inline) "
                + "experimentId=\(ids.experimentId)"
        )
    }

    /// A qualifying interaction with the experience.
    func notificationClicked(_ payload: CEPTriggerPayload, elementId: String?) {
        let ids = identifiers(for: payload)
        var systemData = ids.systemData
        if let cta = elementId?.trimmingCharacters(in: .whitespaces), !cta.isEmpty {
            systemData["call_to_action"] = cta
        }
        bridge.trackSystemEvent(eventName: "notification_click", systemData: systemData, eventData: [:])
        NSLog("[WebEngageEventDispatcher] dispatched: notification_click experimentId=\(ids.experimentId)")
    }

    /// The presentation settled. Terminal, and reached on **both** outcome arms.
    ///
    /// - Parameter displayed: whether the experience actually reached the screen
    ///   — the `dismissed` arm of `PresentationOutcome`. `notification_close` is
    ///   sent only then: a campaign Digia dropped had no notification to close,
    ///   and reporting one would book a close against an impression that never
    ///   happened.
    func experienceEnded(_ payload: CEPTriggerPayload, displayed: Bool) {
        let ids = identifiers(for: payload)

        // Inline already reported its close at view time.
        if displayed, !isInline(payload) {
            bridge.trackSystemEvent(eventName: "notification_close", systemData: ids.systemData, eventData: [:])
            NSLog("[WebEngageEventDispatcher] dispatched: notification_close experimentId=\(ids.experimentId)")
        } else {
            NSLog(
                "[WebEngageEventDispatcher] ended without a close experimentId=\(ids.experimentId) "
                    + "displayed=\(displayed)"
            )
        }
        cache.remove(experimentId: ids.experimentId)
    }

    // MARK: - Identifiers

    /// WebEngage names every analytics event by experiment + variation. The
    /// cached `notificationPrepared` payload is authoritative when present; the
    /// trigger's own metadata is the fallback for a campaign whose cache entry
    /// has already been evicted.
    private func identifiers(for payload: CEPTriggerPayload) -> (experimentId: String, systemData: [String: Any]) {
        let experimentId = payload.cepMetadata["experimentId"] ?? payload.cepCampaignId
        let cachedData = cache.get(experimentId: experimentId)
        let weExperimentId = str(cachedData?["experimentId"]) ?? experimentId
        let weVariationId = str(cachedData?["variationId"])
            ?? payload.cepMetadata["variationId"]
            ?? payload.cepCampaignId

        return (
            experimentId,
            [
                "experiment_id": weExperimentId,
                "id": weVariationId,
            ]
        )
    }

    private func isInline(_ payload: CEPTriggerPayload) -> Bool {
        payload.cepMetadata["type"] == "inline"
    }

    // MARK: - Helper

    private func str(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return s
    }
}
