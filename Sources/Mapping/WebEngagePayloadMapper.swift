import Foundation
import DigiaEngage

/// Maps raw WebEngage in-app / personalization payloads into `CEPTriggerPayload` values.
///
/// One thing couples a WebEngage campaign to a Digia one: the campaign key. It is resolved in
/// this order, and nothing else is a campaign key — not WebEngage's own experiment id, not a
/// placement, not a view id:
///
///   1. a top-level key in the payload, in any of the twelve accepted spellings;
///   2. a `<template id="digia-config">` block with `<meta>` children, found anywhere in the
///      payload's string values.
///
/// The block exists because WebEngage's in-app custom fields are string-valued, so an HTML
/// body is often the only place a marketer can put structured configuration at all.
///
/// Twin of `WebEngagePayloadMapper.kt`; both are translations of
/// `webengage_payload_mapper.dart`, which is the source of truth for this wire contract. A
/// native that parses the block even slightly differently from Flutter is a campaign that
/// renders on one stack and not another, so the regexes and the normalisation below are
/// copied, not reinvented.
internal final class WebEngagePayloadMapper {

    private let config: WebEngagePluginConfig
    private let log = DigiaLogger("WE")

    init(config: WebEngagePluginConfig = WebEngagePluginConfig()) {
        self.config = config
    }

    // MARK: - In-App

    /// Maps a raw `notificationPrepared` dictionary to a `CEPTriggerPayload`, or nil when the
    /// campaign carries no Digia campaign key.
    func map(_ data: [String: Any]) -> CEPTriggerPayload? {
        guard let config = Self.resolveConfig(data) else {
            log.d("In-app payload dropped — no campaign key found (keys=\(data.keys.sorted()))")
            return nil
        }

        return trigger(data, campaignKey: config.campaignKey, variables: config.variables)
    }

    /// Builds a trigger for a payload that names a Digia key but holds no usable value. It
    /// rides the normal deliver path; core drops it as unknown, which writes the health event.
    func mapBadValue(_ data: [String: Any]) -> CEPTriggerPayload? {
        guard let raw = Self.badTopLevelCampaignKey(in: data) else { return nil }
        log.w("In-app payload has a bad campaign key (value=\(raw))")
        return trigger(data, campaignKey: raw, variables: nil)
    }

    private func trigger(
        _ data: [String: Any],
        campaignKey: String,
        variables: [String: String]?
    ) -> CEPTriggerPayload {
        // WebEngage names an in-app campaign by experiment; the campaign key is the fallback
        // so a payload that reached us without one still gets a stable identity rather than
        // being dropped.
        let experimentId = Self.stringValue(data["experimentId"] ?? data["id"] ?? data["campaignId"])
            ?? campaignKey

        // Carried on the trigger so every WebEngage call site derives its ids from one place.
        let variationId = Self.stringValue(data["variationId"]) ?? experimentId

        log.d("In-app payload mapped (campaignKey=\(campaignKey), experimentId=\(experimentId))", campaign: campaignKey)
        return CEPTriggerPayload(
            cepCampaignId: experimentId,
            campaignKey: campaignKey,
            cepMetadata: [
                "experimentId": experimentId,
                "campaignId": experimentId,
                "variationId": variationId,
            ],
            variables: variables
        )
    }

    // MARK: - Inline (WEPersonalization)

    /// Maps a WEPersonalization inline campaign to a `CEPTriggerPayload`.
    ///
    /// One WebEngage campaign can be served into several properties, so the identity is the
    /// pair — two slots showing the same campaign are two presentations.
    ///
    /// `metadata` is the campaign envelope. Dart derives `variationId` and `propertyId` from
    /// the pair because `WECampaignData` never handed it either; here the real ids are
    /// available, and discarding them to match would lose information the analytics call sites
    /// can use. The derived pair stays as the fallback.
    func mapInline(
        campaignId: String,
        targetViewId: String,
        customData: [String: Any],
        metadata: [String: Any] = [:]
    ) -> CEPTriggerPayload? {
        guard !campaignId.isEmpty else {
            log.d("Inline payload dropped — missing campaignId")
            return nil
        }
        guard !targetViewId.isEmpty else {
            log.d("Inline payload dropped — missing targetViewId (campaignId=\(campaignId))")
            return nil
        }
        guard let config = Self.resolveConfig(customData) else {
            log.d("Inline payload dropped — no campaign key found (campaignId=\(campaignId))")
            return nil
        }

        let identity = "\(campaignId):\(targetViewId)"
        log.d("Inline payload mapped (campaignKey=\(config.campaignKey), id=\(identity))", campaign: config.campaignKey)
        return CEPTriggerPayload(
            cepCampaignId: identity,
            campaignKey: config.campaignKey,
            cepMetadata: [
                "experimentId": campaignId,
                "campaignId": campaignId,
                "propertyId": Self.stringValue(metadata["propertyId"]) ?? targetViewId,
                "variationId": Self.stringValue(metadata["variationId"]) ?? identity,
            ],
            variables: config.variables
        )
    }

    // MARK: - The contract

    /// What a marketer authored: the campaign key, and the variables to interpolate with it.
    internal struct CampaignConfig {
        let campaignKey: String
        let variables: [String: String]?
    }

    /// Resolves the campaign key and its variables out of a raw payload, or nil when the
    /// payload carries no Digia campaign key.
    ///
    /// Top-level wins over the HTML block, for the key and for the variables independently —
    /// the block's `<meta>` children are the fallback for each. They are never merged: a
    /// marketer who moved a campaign from the block to top-level fields, or from `args` to
    /// `variables`, must not have the old values leak back in underneath the new ones.
    internal static func resolveConfig(_ data: [String: Any]) -> CampaignConfig? {
        let template = parseDigiaTemplate(in: data)
        guard let campaignKey = topLevelCampaignKey(in: data) ?? template?.campaignKey else {
            return nil
        }
        return CampaignConfig(
            campaignKey: campaignKey,
            variables: resolveVariables(data) ?? template?.variables)
    }

    /// Does this WebEngage campaign belong to Digia?
    ///
    /// The suppression gate's whole question. Deliberately **wider** than ``resolveConfig``: a
    /// `<template id="digia-config">` block claims the campaign whether or not the marketer
    /// remembered to put a campaign key in it, because a block is unambiguously ours and
    /// letting WebEngage render the placeholder underneath it is worse than rendering nothing.
    ///
    /// The width has a cost, and the caller owns it. A campaign this claims but
    /// ``resolveConfig`` cannot map has had WebEngage's renderer suppressed and will never
    /// produce a presentation to settle, so the bridge must take neither the per-experiment
    /// gate nor the cache entry for it — see `notificationPrepared`.
    internal static func isDigiaCampaign(_ data: [String: Any]) -> Bool {
        topLevelCampaignKey(in: data) != nil
            || badTopLevelCampaignKey(in: data) != nil
            || containsDigiaTemplateBlock(in: data)
    }

    /// The raw value of a top-level campaign key that is present but unusable (blank or not a
    /// string), or nil when the payload has a usable key or none at all.
    internal static func badTopLevelCampaignKey(in data: [String: Any]) -> String? {
        guard topLevelCampaignKey(in: data) == nil,
              let name = campaignKeyNames.first(where: { data[$0] != nil }) else { return nil }
        return stringValue(data[name]) ?? ""
    }

    /// Accepted spellings of the campaign key, in priority order.
    ///
    /// A marketer types this by hand on the WebEngage dashboard, so every plausible casing and
    /// separator is accepted rather than silently dropping the campaign. Deliberately
    /// identical to the CleverTap and MoEngage lists — a spelling learned on one CEP must not
    /// have to be relearned on another.
    internal static let campaignKeyNames = [
        "digiaKey", "digia_key", "digia-key",
        "campaignKey", "campaign_key", "campaign-key",
        "digiaCampaign", "digia_campaign", "digia-campaign",
        "digiaCampaignKey", "digia_campaign_key", "digia-campaign-key",
    ]

    /// The first accepted spelling whose value is a non-empty string, trimmed.
    private static func topLevelCampaignKey(in data: [String: Any]) -> String? {
        for name in campaignKeyNames {
            if let value = (data[name] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    // MARK: - Variables

    /// The runtime variables to interpolate into the campaign config.
    ///
    /// `args` is the older spelling, kept because campaigns authored against it are live. The
    /// first of the two that resolves to an object wins; nothing is merged.
    private static func resolveVariables(_ data: [String: Any]) -> [String: String]? {
        for name in ["variables", "args"] {
            guard let object = jsonObject(data[name]) else { continue }
            var out: [String: String] = [:]
            for (key, value) in object {
                if let flat = flattenedString(value), !flat.isEmpty { out[key] = flat }
            }
            return out.isEmpty ? nil : out
        }
        return nil
    }

    /// A `variables` / `args` value as an object.
    ///
    /// A serialised blob counts. WebEngage's in-app custom fields are string-valued, so an
    /// object a marketer typed on the dashboard reaches us as JSON text — the same constraint
    /// the `<template id="digia-config">` form exists to work around.
    private static func jsonObject(_ raw: Any?) -> [String: Any]? {
        switch raw {
        case let map as [String: Any]:
            return map
        case let map as [AnyHashable: Any]:
            var out: [String: Any] = [:]
            for (key, value) in map {
                if let key = key as? String { out[key] = value }
            }
            return out
        case let text as String:
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return object
        default:
            return nil
        }
    }

    /// Flattens a scalar to the string a campaign config interpolates. Arrays, objects and
    /// null have no flat form and are dropped.
    private static func flattenedString(_ value: Any) -> String? {
        switch value {
        case let s as String:
            return s
        // Every JSON number arrives as an NSNumber, and an NSNumber bridges to `Bool` as
        // readily as to `Int` — `case let b as Bool` above the numeric cases matched a plain
        // `1` and rendered an authored count as "true". Only the CFBoolean singletons are
        // really booleans.
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return String(n.boolValue) }
            let d = n.doubleValue
            return d == d.rounded() && abs(d) < 1e15 ? String(n.int64Value) : String(d)
        default:
            return nil
        }
    }

    // MARK: - <template id="digia-config">

    private struct TemplateConfig {
        let campaignKey: String
        let variables: [String: String]?
    }

    private static let templateRegex = regex(
        #"<template\b[^>]*\bid\s*=\s*["']digia-config["'][^>]*>(.*?)</template>"#,
        [.caseInsensitive, .dotMatchesLineSeparators])

    private static let metaTagRegex = regex(#"<meta\b([^>]*?)(?:/>|>)"#, [.caseInsensitive])

    private static let attrRegex = regex(#"(\w[\w-]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|(\S+)))?"#)

    /// Whether a `<template id="digia-config">` block appears anywhere in the payload's string
    /// values, regardless of what its `<meta>` children say.
    private static func containsDigiaTemplateBlock(in data: [String: Any]) -> Bool {
        guard let templateRegex else { return false }
        return collectTextCandidates(data).contains { text in
            templateRegex.firstMatch(in: text, range: wholeRange(of: text)) != nil
        }
    }

    /// Scans string values for `<template id="digia-config">` and reads the campaign key and
    /// the variables out of its `<meta>` children.
    ///
    /// A `<meta>` whose `name` normalises to one of the twelve accepted spellings supplies the
    /// campaign key; every other `<meta>` becomes a variable, `name` → `content`.
    private static func parseDigiaTemplate(in data: [String: Any]) -> TemplateConfig? {
        guard let templateRegex, let metaTagRegex else { return nil }

        for text in collectTextCandidates(data) {
            for templateMatch in templateRegex.matches(in: text, range: wholeRange(of: text)) {
                guard let body = group(templateMatch, 1, in: text) else { continue }

                var campaignKey: String?
                var variables: [String: String] = [:]

                for metaMatch in metaTagRegex.matches(in: body, range: wholeRange(of: body)) {
                    let attrs = parseHtmlAttributes(group(metaMatch, 1, in: body) ?? "")
                    guard let name = stringValue(attrs["name"]),
                          let content = stringValue(attrs["content"]) else { continue }

                    if isCampaignKeyName(name) {
                        campaignKey = content
                    } else {
                        variables[name] = content
                    }
                }

                if let campaignKey {
                    return TemplateConfig(
                        campaignKey: campaignKey,
                        variables: variables.isEmpty ? nil : variables)
                }
            }
        }
        return nil
    }

    /// Pre-computed set of the accepted spellings, lowercased with `-` and `_` stripped.
    private static let normalizedCampaignKeyNames = Set(campaignKeyNames.map(normalizeKeyName))

    private static func normalizeKeyName(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }

    private static func isCampaignKeyName(_ name: String) -> Bool {
        normalizedCampaignKeyNames.contains(normalizeKeyName(name))
    }

    private static func parseHtmlAttributes(_ attrsString: String) -> [String: String] {
        guard let attrRegex else { return [:] }
        var result: [String: String] = [:]
        for match in attrRegex.matches(in: attrsString, range: wholeRange(of: attrsString)) {
            guard let key = group(match, 1, in: attrsString), !key.isEmpty else { continue }
            let value = group(match, 2, in: attrsString)
                ?? group(match, 3, in: attrsString)
                ?? group(match, 4, in: attrsString)
                ?? ""
            result[key] = htmlUnescape(value)
        }
        return result
    }

    /// Every string anywhere in the payload that could hold markup.
    private static func collectTextCandidates(_ root: Any) -> [String] {
        var results: [String] = []
        var queue: [Any] = [root]
        while !queue.isEmpty {
            switch queue.removeFirst() {
            case let s as String:
                if s.contains("<") { results.append(s) }
            case let map as [String: Any]:
                queue.append(contentsOf: map.values)
            case let map as [AnyHashable: Any]:
                queue.append(contentsOf: map.values)
            case let list as [Any]:
                queue.append(contentsOf: list)
            default:
                break
            }
        }
        return results
    }

    internal static func htmlUnescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: - Helpers

    /// The patterns above are compile-time constants, so a nil here is a programmer error, not
    /// a data one: loud in debug and live test, and degraded — never a crash — in a release
    /// running inside a customer's app.
    private static func regex(
        _ pattern: String,
        _ options: NSRegularExpression.Options = []
    ) -> NSRegularExpression? {
        let compiled = try? NSRegularExpression(pattern: pattern, options: options)
        assert(compiled != nil, "malformed pattern: \(pattern)")
        return compiled
    }

    private static func wholeRange(of text: String) -> NSRange {
        NSRange(text.startIndex..., in: text)
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        guard index < match.numberOfRanges,
              let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }

    /// Trimmed, or nil when there is nothing left.
    private static func stringValue(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        let text = (value as? String) ?? String(describing: value)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
