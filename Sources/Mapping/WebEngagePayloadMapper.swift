import Foundation
import DigiaEngage

/// Maps raw WebEngage in-app / personalization payloads into `CEPTriggerPayload` values.
/// Mirrors `WebEngagePayloadMapper.kt` on Android.
internal final class WebEngagePayloadMapper {

    private let config: WebEngagePluginConfig

    init(config: WebEngagePluginConfig = WebEngagePluginConfig()) {
        self.config = config
    }

    // MARK: - In-App (modal / nudge)

    /// Maps a raw `notificationPrepared` dictionary to zero or more `CEPTriggerPayload`s.
    func map(_ data: [String: Any]) -> [CEPTriggerPayload] {
        let normalized = normalizeWithDigiaContract(data)

        guard let campaignId = str(normalized["experimentId"] ?? normalized["id"] ?? normalized["campaignId"]) else {
            logDebug("inapp_map_dropped reason=missing_campaign_id keys=\(data.keys.sorted())")
            return []
        }

        let screenId    = str(normalized["screenId"] ?? normalized["screen_id"])
        let variationId = str(normalized["variationId"])
        let layoutId    = str(normalized["layoutId"])
        let type        = str(normalized["type"])?.lowercased()
        let command     = str(normalized["command"])?.uppercased()
        let viewId      = str(normalized["viewId"])
        let args        = flattenedVariables(normalizeArgs(normalized["args"]))

        var payloads: [CEPTriggerPayload] = []

        if type == "inline" {
            guard let pk = str(normalized["placementKey"]), let vid = viewId else {
                let reason = str(normalized["placementKey"]) == nil ? "missing_placementKey" : "missing_viewId"
                logDebug("inapp_inline_not_mapped campaignId=\(campaignId) reason=\(reason)")
                return []
            }
            payloads.append(CEPTriggerPayload(
                cepCampaignId: campaignId,
                campaignKey: pk,
                cepMetadata: buildMetadata(
                    campaignId: campaignId, variationId: variationId, layoutId: layoutId,
                    type: "inline", command: nil, viewId: vid, screenId: screenId
                ),
                variables: args
            ))
        } else if let cmd = command, let vid = viewId {
            payloads.append(CEPTriggerPayload(
                cepCampaignId: campaignId,
                campaignKey: vid,
                cepMetadata: buildMetadata(
                    campaignId: campaignId, variationId: variationId, layoutId: layoutId,
                    type: contentType(forCommand: cmd), command: cmd, viewId: vid, screenId: screenId
                ),
                variables: args
            ))
        } else {
            logDebug("inapp_nudge_not_mapped campaignId=\(campaignId) reason=unsupported_or_incomplete_contract")
        }

        logDebug("inapp_map_result campaignId=\(campaignId) mapped=\(payloads.count)")
        return payloads
    }

    // MARK: - Inline (WEPersonalization)

    /// Maps a WEPersonalization inline campaign to a `CEPTriggerPayload`.
    func mapInline(
        campaignId: String,
        targetViewId: String,
        customData: [String: Any],
        metadata: [String: Any]
    ) -> CEPTriggerPayload? {
        guard !campaignId.isEmpty else {
            logDebug("inline_map_dropped reason=missing_campaign_id"); return nil
        }
        guard !targetViewId.isEmpty else {
            logDebug("inline_map_dropped campaignId=\(campaignId) reason=missing_targetViewId"); return nil
        }

        let screenId    = str(customData["screenId"] ?? customData["screen_id"])
        let variationId = str(metadata["variationId"])
        let propertyId  = str(metadata["propertyId"]) ?? targetViewId
        let componentId = str(customData["componentId"])

        guard let vid = componentId else {
            logDebug("inline_map_dropped campaignId=\(campaignId) targetViewId=\(targetViewId) reason=missing_componentId")
            return nil
        }

        let args = flattenedVariables(normalizeArgs(customData["args"]))
        var cepMetadata: [String: String] = [
            "experimentId": campaignId,
            "campaignId": campaignId,
            "propertyId": propertyId,
            "targetViewId": targetViewId,
            "type": "inline",
        ]
        if let v = variationId { cepMetadata["variationId"] = v }
        if let s = screenId { cepMetadata["screenId"] = s }

        let payload = CEPTriggerPayload(
            cepCampaignId: campaignId,
            campaignKey: targetViewId,
            cepMetadata: cepMetadata,
            variables: args
        )
        logDebug("inline_map_result campaignId=\(campaignId) targetViewId=\(targetViewId) payloadId=\(payload.cepCampaignId)")
        return payload
    }

    // MARK: - Helpers

    private func buildMetadata(
        campaignId: String,
        variationId: String?,
        layoutId: String?,
        type: String,
        command: String?,
        viewId: String?,
        screenId: String?
    ) -> [String: String] {
        var ctx: [String: String] = ["experimentId": campaignId, "campaignId": campaignId, "type": type]
        if let v = variationId { ctx["variationId"] = v }
        if let l = layoutId   { ctx["layoutId"] = l }
        if let c = command    { ctx["command"] = c }
        if let vid = viewId   { ctx["viewId"] = vid }
        if let s = screenId   { ctx["screenId"] = s }
        return ctx
    }

    private func contentType(forCommand command: String) -> String {
        switch command {
        case "SHOW_DIALOG":       return "dialog"
        case "SHOW_BOTTOM_SHEET": return "bottomsheet"
        default:                  return "dialog"
        }
    }

    // MARK: - Flat variable conversion

    /// Flattens a raw args dictionary into `[String: String]?` for `CEPTriggerPayload.variables`.
    /// Nested objects/arrays have no flat representation and are dropped.
    private func flattenedVariables(_ raw: [String: Any]) -> [String: String]? {
        var out: [String: String] = [:]
        for (key, value) in raw {
            switch value {
            case let s as String: out[key] = s
            case let b as Bool: out[key] = String(b)
            case let n as Int: out[key] = String(n)
            case let n as Double: out[key] = String(n)
            case is NSNull, is [String: Any], is [Any]: continue
            default: out[key] = String(describing: value)
            }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - String extractor

    internal func str(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return s
    }

    private func logDebug(_ message: String) {
        if config.diagnosticsEnabled { NSLog("[DigiaWEMapper] \(message)") }
    }
}
