import Foundation

// MARK: - Contract extraction (mirrors DigiaInAppContract.kt)

/// Merges a Digia rendering contract extracted from `raw` into a copy of `raw`,
/// or returns `raw` unchanged when no contract is found.
///
/// Contract sources are tried in priority order:
/// 1. Top-level keys — `campaignKey` or one of its aliases present directly in `raw`.
/// 2. `<template id="digia-config">` HTML block with `<meta name="..." content="...">` children
///    (the convention shared by the RN and Flutter WebEngage plugins).
/// 3. `<digia ...>` HTML tag embedded in any string value (legacy scheme).
internal func normalizeWithDigiaContract(_ raw: [String: Any]) -> [String: Any] {
    guard let contract = contractExtractor.extract(raw) else { return raw }
    return raw.merging(contract) { _, new in new }
}

private let contractExtractor = DigiaContractExtractor(sources: [
    TopLevelContractSource(),
    TemplateMetaContractSource(),
    HtmlDigiaTagContractSource(),
])

// MARK: - Extractor

internal final class DigiaContractExtractor: @unchecked Sendable {
    private let sources: [ContractSource]
    init(sources: [ContractSource]) { self.sources = sources }

    func extract(_ raw: [String: Any]) -> [String: Any]? {
        for source in sources {
            if let contract = source.extract(raw) { return contract }
        }
        return nil
    }
}

internal protocol ContractSource {
    func extract(_ raw: [String: Any]) -> [String: Any]?
}

// MARK: - Top-level source

internal final class TopLevelContractSource: ContractSource {
    func extract(_ raw: [String: Any]) -> [String: Any]? {
        return buildContract(raw, source: "top_level")
    }
}

// MARK: - <template id="digia-config"> HTML block source

internal final class TemplateMetaContractSource: ContractSource {
    private static let templateRegex = try! NSRegularExpression(
        pattern: #"<template\b[^>]*\bid\s*=\s*["']digia-config["'][^>]*>([\s\S]*?)</template>"#,
        options: [.caseInsensitive]
    )
    private static let metaRegex = try! NSRegularExpression(
        pattern: #"<meta\b[^>]*\bname\s*=\s*["']([^"']+)["'][^>]*\bcontent\s*=\s*["']([^"']*)["'][^>]*>"#,
        options: [.caseInsensitive]
    )

    func extract(_ raw: [String: Any]) -> [String: Any]? {
        for text in collectTemplateTextCandidates(raw) {
            let nsText = text as NSString
            let templateMatches = Self.templateRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            for templateMatch in templateMatches {
                guard templateMatch.numberOfRanges > 1 else { continue }
                let body = nsText.substring(with: templateMatch.range(at: 1))
                let nsBody = body as NSString
                var campaignKey: String?
                var args: [String: Any] = [:]
                let metaMatches = Self.metaRegex.matches(in: body, range: NSRange(location: 0, length: nsBody.length))
                for metaMatch in metaMatches {
                    guard metaMatch.numberOfRanges > 2 else { continue }
                    let name = nsBody.substring(with: metaMatch.range(at: 1)).trimmingCharacters(in: .whitespaces)
                    let content = nsBody.substring(with: metaMatch.range(at: 2)).trimmingCharacters(in: .whitespaces)
                    if content.isEmpty { continue }
                    if isCampaignKeyAlias(name) {
                        if campaignKey == nil { campaignKey = content }
                    } else if !name.isEmpty {
                        args[name] = content
                    }
                }
                guard let key = campaignKey else { continue }
                return [
                    "campaignKey": key,
                    "args": args,
                    "digiaContractSource": "template_meta",
                ]
            }
        }
        return nil
    }
}

// MARK: - HTML <digia …> tag source

internal final class HtmlDigiaTagContractSource: ContractSource {
    func extract(_ raw: [String: Any]) -> [String: Any]? {
        for text in collectTextCandidates(raw) {
            for tagMap in DigiaTagParser.parseAll(html: text) {
                if let contract = buildContract(tagMap, source: "html_digia_tag") {
                    return contract
                }
            }
        }
        return nil
    }
}

// MARK: - Contract builder

/// Top-level key names that carry a `campaignKey` value — mirrors the RN and Flutter
/// WebEngage plugins' `CAMPAIGN_KEY_NAMES` list so all platforms recognize the same
/// dashboard-authored campaign data.
private let campaignKeyAliases: [String] = [
    "campaignKey", "campaign_key", "campaign-key",
    "digiaKey", "digia_key", "digia-key",
    "digiaCampaign", "digia_campaign", "digia-campaign",
    "digiaCampaignKey", "digia_campaign_key", "digia-campaign-key",
]

private let normalizedCampaignKeyAliases: Set<String> = Set(campaignKeyAliases.map(normalizeAliasName))

private func normalizeAliasName(_ name: String) -> String {
    return name.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
}

private func isCampaignKeyAlias(_ name: String) -> Bool {
    return normalizedCampaignKeyAliases.contains(normalizeAliasName(name))
}

/// Validates and normalizes a raw attribute / key map into a Digia contract.
///
/// Returns `nil` when the data doesn't form a complete valid contract: requires a non-blank
/// `campaignKey` (or one of its aliases in `campaignKeyAliases`) — the coupling key that links
/// the CEP campaign to a Digia dashboard campaign config.
private func buildContract(_ raw: [String: Any], source: String) -> [String: Any]? {
    var campaignKey: String?
    for alias in campaignKeyAliases {
        if let v = (raw[alias] as? String)?.trimmingCharacters(in: .whitespaces), !v.isEmpty {
            campaignKey = v
            break
        }
    }
    guard let key = campaignKey else { return nil }

    let type = (raw["type"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased().nilIfEmpty()
    let rawScreenId = raw["screenId"] ?? raw["screen_id"]
    let screenId = (rawScreenId as? String)?.trimmingCharacters(in: .whitespaces).nilIfEmpty()
    let args = normalizeArgs(raw["args"])

    var result: [String: Any] = [
        "campaignKey": key,
        "args": args,
        "digiaContractSource": source,
    ]
    if let t = type       { result["type"]     = t   }
    if let sid = screenId { result["screenId"] = sid }
    return result
}

internal func normalizeArgs(_ raw: Any?) -> [String: Any] {
    switch raw {
    case nil: return [:]
    case let map as [String: Any]: return map
    case let map as [AnyHashable: Any]:
        var out: [String: Any] = [:]
        map.forEach { if let k = $0.key as? String { out[k] = $0.value } }
        return out
    case let string as String:
        guard let data = string.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return [:] }
        return dict
    default: return [:]
    }
}

// MARK: - Text candidate collector

internal func collectTextCandidates(_ root: Any) -> [String] {
    var results: [String] = []
    var queue: [Any] = [root]
    while !queue.isEmpty {
        let node = queue.removeFirst()
        switch node {
        case let s as String:
            if s.range(of: "<digia", options: .caseInsensitive) != nil { results.append(s) }
        case let map as [String: Any]:
            queue.append(contentsOf: map.values)
        case let map as [AnyHashable: Any]:
            queue.append(contentsOf: map.values)
        case let list as [Any]:
            queue.append(contentsOf: list)
        default: break
        }
    }
    return results
}

private func collectTemplateTextCandidates(_ root: Any) -> [String] {
    var results: [String] = []
    var queue: [Any] = [root]
    while !queue.isEmpty {
        let node = queue.removeFirst()
        switch node {
        case let s as String:
            if s.range(of: "digia-config", options: .caseInsensitive) != nil { results.append(s) }
        case let map as [String: Any]:
            queue.append(contentsOf: map.values)
        case let map as [AnyHashable: Any]:
            queue.append(contentsOf: map.values)
        case let list as [Any]:
            queue.append(contentsOf: list)
        default: break
        }
    }
    return results
}

// MARK: - String helper

internal extension String {
    func nilIfEmpty() -> String? { isEmpty ? nil : self }
}
