import Foundation
import DigiaEngage

/// Translates `DigiaExperienceEvent` + `CEPTriggerPayload` into WebEngage analytics calls.
/// Mirrors `WebEngageEventDispatcher.kt` on Android.
@MainActor
internal final class WebEngageEventDispatcher {

    private let bridge: WebEngageBridgeProtocol
    private let cache: InAppDataCache
    private let config: WebEngagePluginConfig

    init(bridge: WebEngageBridgeProtocol, cache: InAppDataCache, config: WebEngagePluginConfig) {
        self.bridge = bridge
        self.cache = cache
        self.config = config
    }

    // MARK: - Public

    func forwardScreen(_ name: String) {
        bridge.navigateScreen(name)
    }

    /// Returns `true` when the event was dispatched.
    ///
    /// Routing is driven by `payload.cepMetadata["type"]`:
    /// - `"inline"` → `notification_*` system events (WE Personalization has no lifecycle API;
    ///   impression emits `notification_view` + `notification_close`, click emits
    ///   `notification_click`). Dismissed is a no-op for inline.
    /// - Other → `notification_*` system events (WE in-app API).
    @discardableResult
    func dispatch(event: DigiaExperienceEvent, payload: CEPTriggerPayload) -> Bool {
        if payload.cepMetadata["type"] == "inline" {
            dispatchInlineEvent(event: event, payload: payload)
            return true
        }
        return dispatchInAppEvent(event: event, payload: payload)
    }

    // MARK: - In-App

    private func dispatchInAppEvent(event: DigiaExperienceEvent, payload: CEPTriggerPayload) -> Bool {
        let experimentId = payload.cepMetadata["experimentId"] ?? payload.cepCampaignId

        let cachedData = cache.get(experimentId: experimentId)
        let weExperimentId = str(cachedData?["experimentId"]) ?? experimentId
        let weVariationId  = str(cachedData?["variationId"])
                          ?? payload.cepMetadata["variationId"]
                          ?? payload.cepCampaignId

        let eventName: String
        switch event {
        case .impressed:  eventName = "notification_view"
        case .clicked:    eventName = "notification_click"
        case .dismissed:  eventName = "notification_close"
        }

        var systemData: [String: Any] = [
            "experiment_id": weExperimentId,
            "id": weVariationId,
        ]
        if case .clicked(let elementID) = event,
           let cta = elementID?.trimmingCharacters(in: .whitespaces),
           !cta.isEmpty {
            systemData["call_to_action"] = cta
        }

        bridge.trackSystemEvent(eventName: eventName, systemData: systemData, eventData: [:])

        if case .dismissed = event {
            bridge.releaseCampaignGate(experimentId)
            cache.remove(experimentId: experimentId)
            logDebug("dispatched: \(eventName) experimentId=\(experimentId) (evicted)")
        } else {
            logDebug("dispatched: \(eventName) experimentId=\(experimentId)")
        }
        return true
    }

    // MARK: - Inline

    private func dispatchInlineEvent(event: DigiaExperienceEvent, payload: CEPTriggerPayload) {
        if case .dismissed = event { return }

        let experimentId = payload.cepMetadata["experimentId"] ?? payload.cepCampaignId
        let cachedData = cache.get(experimentId: experimentId)
        let weExperimentId = str(cachedData?["experimentId"]) ?? experimentId
        let weVariationId  = str(cachedData?["variationId"])
                          ?? payload.cepMetadata["variationId"]
                          ?? payload.cepCampaignId

        var systemData: [String: Any] = [
            "experiment_id": weExperimentId,
            "id": weVariationId,
        ]

        switch event {
        case .impressed:
            bridge.trackSystemEvent(eventName: "notification_view", systemData: systemData, eventData: [:])
            bridge.trackSystemEvent(eventName: "notification_close", systemData: systemData, eventData: [:])
            bridge.releaseCampaignGate(experimentId)
            cache.remove(experimentId: experimentId)
            logDebug("dispatched: notification_view + notification_close (inline) experimentId=\(experimentId)")
        case .clicked(let elementID):
            if let cta = elementID?.trimmingCharacters(in: .whitespaces), !cta.isEmpty {
                systemData["call_to_action"] = cta
            }
            bridge.trackSystemEvent(eventName: "notification_click", systemData: systemData, eventData: [:])
            logDebug("dispatched: notification_click (inline) experimentId=\(experimentId)")
        case .dismissed:
            break
        }
    }

    // MARK: - Helper

    private func str(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return s
    }

    private func logDebug(_ message: String) {
        if config.diagnosticsEnabled { NSLog("[Digia WebEngage] \(message)") }
    }
}
