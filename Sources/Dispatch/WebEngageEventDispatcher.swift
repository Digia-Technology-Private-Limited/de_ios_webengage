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
    private let log = DigiaLogger("WE")

    init(bridge: WebEngageBridgeProtocol, cache: InAppDataCache) {
        self.bridge = bridge
        self.cache = cache
    }

    // MARK: - Public

    func forwardScreen(_ screenName: String) {
        log.d("Screen forwarded (screen=\(screenName))")
        bridge.navigateScreen(screenName)
    }

    /// The experience became visible.
    func notificationViewed(_ payload: CEPTriggerPayload) {
        let ids = identifiers(for: payload)
        log.i("CEP impression marked (notification_view, experimentId=\(ids.experimentId))", campaign: payload.campaignKey)
        bridge.trackSystemEvent(eventName: "notification_view", systemData: ids.systemData, eventData: [:])
    }

    /// A qualifying interaction with the experience.
    func notificationClicked(_ payload: CEPTriggerPayload, elementId: String?) {
        let ids = identifiers(for: payload)
        var systemData = ids.systemData
        let cta = elementId.flatMap { raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let cta {
            systemData["call_to_action"] = cta
        }
        log.i("CEP click marked (notification_click, experimentId=\(ids.experimentId), cta=\(cta ?? "-"))", campaign: payload.campaignKey)
        bridge.trackSystemEvent(eventName: "notification_click", systemData: systemData, eventData: [:])
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

        if displayed {
            log.i("CEP close marked (notification_close, experimentId=\(ids.experimentId))", campaign: payload.campaignKey)
            bridge.trackSystemEvent(eventName: "notification_close", systemData: ids.systemData, eventData: [:])
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

    // MARK: - Helper

    private func str(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return s
    }
}
