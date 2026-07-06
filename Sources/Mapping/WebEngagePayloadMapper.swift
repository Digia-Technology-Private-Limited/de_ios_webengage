import Foundation
import DigiaEngage

/// Maps raw WebEngage in-app / personalization payloads into `CEPTriggerPayload` values.
/// Mirrors `WebEngagePayloadMapper.kt` on Android.
internal final class WebEngagePayloadMapper {

    private let config: WebEngagePluginConfig

    init(config: WebEngagePluginConfig = WebEngagePluginConfig()) {
        self.config = config
    }

    // MARK: - In-App (modal / nudge / inline)

    /// Maps a raw `notificationPrepared` dictionary to zero or one `CEPTriggerPayload`s.
    ///
    /// Requires a non-blank `campaignKey` — the coupling key that links this WE campaign to a
    /// Digia dashboard campaign config. Payloads without one are dropped.
    func map(_ data: [String: Any]) -> [CEPTriggerPayload] {
        let normalized = normalizeWithDigiaContract(data)

        guard let campaignKey = str(normalized["campaignKey"]) else {
            logDebug("inapp_map_dropped reason=missing_campaignKey keys=\(data.keys.sorted())")
            return []
        }

        let experimentId = str(normalized["experimentId"] ?? normalized["id"] ?? normalized["campaignId"]) ?? campaignKey

        var meta: [String: String] = ["experimentId": experimentId]
        if let variationId = str(normalized["variationId"]) { meta["variationId"] = variationId }
        if let layoutId    = str(normalized["layoutId"])    { meta["layoutId"]    = layoutId }
        if let type        = str(normalized["type"])        { meta["type"]       = type }

        let payload = CEPTriggerPayload(
            cepCampaignId: experimentId,
            campaignKey: campaignKey,
            cepMetadata: meta,
            variables: stringifyArgs(normalizeArgs(normalized["args"]))
        )

        logDebug("inapp_map_result campaignId=\(experimentId) mapped=1 campaignKey=\(campaignKey)")
        return [payload]
    }

    // MARK: - Helpers

    private func stringifyArgs(_ args: [String: Any]) -> [String: String]? {
        var out: [String: String] = [:]
        args.forEach { key, value in
            if !(value is NSNull) { out[key] = String(describing: value) }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - String extractor

    internal func str(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return s
    }

    private func logDebug(_ message: String) {
        if config.diagnosticsEnabled { NSLog("[Digia WebEngage] \(message)") }
    }
}
