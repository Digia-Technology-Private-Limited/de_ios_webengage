import Foundation

/// Parses `<digia …>` HTML tags from a string and returns each tag's attributes as a dictionary.
/// Mirrors `DigiaTagParser.kt` on Android.
internal enum DigiaTagParser {

    static func parseAll(html: String) -> [[String: Any]] {
        var results: [[String: Any]] = []
        var pos = html.startIndex

        while pos < html.endIndex {
            guard let tagRange = html.range(of: "<digia", options: .caseInsensitive, range: pos..<html.endIndex) else { break }
            let nameEnd = tagRange.upperBound
            let boundary = nameEnd < html.endIndex ? html[nameEnd] : Character(" ")
            guard isTagBoundary(boundary) else { pos = html.index(after: tagRange.lowerBound); continue }

            guard let closeInfo = scanToTagClose(html, from: nameEnd) else {
                pos = html.index(after: tagRange.lowerBound)
                break
            }

            let selfClosing = closeInfo.selfClosing
            let attrsEnd = closeInfo.attrsEnd
            let tagEnd = closeInfo.tagEnd

            let rawAttrs = String(html[nameEnd..<attrsEnd]).trimmingCharacters(in: .whitespaces)
            let attrs = parseAttributes(rawAttrs)
            if !attrs.isEmpty { results.append(mapAttributes(attrs)) }

            if selfClosing {
                pos = tagEnd
            } else {
                if let closeRange = html.range(of: "</digia>", options: .caseInsensitive, range: tagEnd..<html.endIndex) {
                    pos = closeRange.upperBound
                } else {
                    pos = tagEnd
                }
            }
        }
        return results
    }

    // MARK: - Private

    private struct CloseInfo {
        let attrsEnd: String.Index
        let tagEnd: String.Index
        let selfClosing: Bool
    }

    private static func scanToTagClose(_ html: String, from: String.Index) -> CloseInfo? {
        var i = from
        var inDouble = false
        var inSingle = false
        while i < html.endIndex {
            let ch = html[i]
            if inDouble {
                if ch == "\"" { inDouble = false }
            } else if inSingle {
                if ch == "'" { inSingle = false }
            } else if ch == "\"" {
                inDouble = true
            } else if ch == "'" {
                inSingle = true
            } else if ch == ">" {
                let tagEnd = html.index(after: i)
                // check for self-close: last non-whitespace before '>' is '/'
                var back = i
                var selfClosing = false
                while back > from {
                    back = html.index(before: back)
                    let bc = html[back]
                    if bc == "/" { selfClosing = true; break }
                    if !bc.isWhitespace { break }
                }
                let attrsEnd = selfClosing ? back : i
                return CloseInfo(attrsEnd: attrsEnd, tagEnd: tagEnd, selfClosing: selfClosing)
            }
            i = html.index(after: i)
        }
        return nil
    }

    private static func isTagBoundary(_ ch: Character) -> Bool {
        return ch == " " || ch == "\t" || ch == "\n" || ch == "\r" || ch == ">" || ch == "/"
    }

    private static func parseAttributes(_ rawAttrs: String) -> [String: String] {
        guard !rawAttrs.isEmpty else { return [:] }
        var result: [String: String] = [:]
        var i = rawAttrs.startIndex
        let len = rawAttrs.endIndex

        while i < len {
            // skip whitespace
            while i < len && rawAttrs[i].isWhitespace { i = rawAttrs.index(after: i) }
            guard i < len else { break }

            // read key
            let keyStart = i
            while i < len && (rawAttrs[i].isLetter || rawAttrs[i].isNumber || rawAttrs[i] == "-" || rawAttrs[i] == "_") {
                i = rawAttrs.index(after: i)
            }
            let key = String(rawAttrs[keyStart..<i])
            if key.isEmpty { if i < len { i = rawAttrs.index(after: i) }; continue }

            // skip whitespace
            while i < len && rawAttrs[i].isWhitespace { i = rawAttrs.index(after: i) }
            guard i < len, rawAttrs[i] == "=" else { continue }
            i = rawAttrs.index(after: i) // consume '='

            // skip whitespace
            while i < len && rawAttrs[i].isWhitespace { i = rawAttrs.index(after: i) }
            guard i < len else { break }

            let value: String
            let quoteChar = rawAttrs[i]
            if quoteChar == "\"" || quoteChar == "'" {
                i = rawAttrs.index(after: i)
                let start = i
                while i < len && rawAttrs[i] != quoteChar { i = rawAttrs.index(after: i) }
                value = String(rawAttrs[start..<i])
                if i < len { i = rawAttrs.index(after: i) }
            } else {
                let start = i
                while i < len && !rawAttrs[i].isWhitespace { i = rawAttrs.index(after: i) }
                value = String(rawAttrs[start..<i])
            }
            result[key] = value
        }
        return result
    }

    private static func mapAttributes(_ attrs: [String: String]) -> [String: Any] {
        var out: [String: Any] = [:]
        if let t = attrs["type"]    { out["type"]         = t }
        if let c = attrs["command"] { out["command"]      = c }
        let viewId = attrs["view-id"] ?? attrs["view_id"] ?? attrs["viewId"]
        if let v = viewId { out["viewId"] = v }
        let placement = attrs["placement"] ?? attrs["placement-key"] ?? attrs["placement_key"] ?? attrs["placementKey"]
        if let p = placement { out["placementKey"] = p }
        let screenId = attrs["screen-id"] ?? attrs["screen_id"] ?? attrs["screenId"]
        if let s = screenId { out["screenId"] = s }
        let campaignKeyAttrNames = [
            "campaign-key", "campaign_key", "campaignKey",
            "digia-key", "digia_key", "digiaKey",
            "digia-campaign", "digia_campaign", "digiaCampaign",
            "digia-campaign-key", "digia_campaign_key", "digiaCampaignKey",
        ]
        var campaignKey: String?
        for name in campaignKeyAttrNames {
            if let value = attrs[name] { campaignKey = value; break }
        }
        if let ck = campaignKey { out["campaignKey"] = ck }
        if let rawArgs = attrs["args"]?.trimmingCharacters(in: .whitespaces), !rawArgs.isEmpty,
           let data = htmlUnescape(rawArgs).data(using: .utf8),
           let obj  = try? JSONSerialization.jsonObject(with: data),
           let dict = obj as? [String: Any] {
            out["args"] = dict
        }
        return out
    }

    static func htmlUnescape(_ value: String) -> String {
        return value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
