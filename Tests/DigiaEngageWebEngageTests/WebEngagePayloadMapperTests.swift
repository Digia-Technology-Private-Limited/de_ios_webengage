@testable import DigiaEngage
@testable import DigiaEngageWebEngage
import Foundation
import Testing

/// The coupling question: which string does Digia look the campaign up by?
///
/// WebEngage's own experiment id is a generated token, and a mapper that hands that to core
/// produces "no campaign for key" for every correctly-authored campaign — the failure these
/// exist to catch, because it is silent at the CEP boundary and only visible in a log line far
/// downstream. The key the marketer typed is either a top-level field or a `<meta>` inside a
/// `<template id="digia-config">` block, and the twelve spellings below are the same set
/// CleverTap and MoEngage accept.
///
/// Twin of `WebEngagePayloadMapperTest.kt` in the Android plugin.
@MainActor
struct WebEngagePayloadMapperTests {

    private let mapper = WebEngagePayloadMapper(
        config: WebEngagePluginConfig(diagnosticsEnabled: false))

    // MARK: - The campaign key

    @Test("reads the campaign key the marketer typed, in every accepted spelling")
    func everySpelling() {
        for spelling in WebEngagePayloadMapper.campaignKeyNames {
            let payload = mapper.map(["experimentId": "exp_1", spelling: "welcome_nudge"])
            #expect(payload?.campaignKey == "welcome_nudge", "spelling \(spelling)")
        }
    }

    @Test("prefers the earlier spelling when a payload carries two")
    func priorityOrder() {
        let payload = mapper.map(["campaign_key": "second", "digiaKey": "first"])
        #expect(payload?.campaignKey == "first")
    }

    @Test("trims a key the marketer left whitespace around")
    func trims() {
        #expect(mapper.map(["digiaKey": "  welcome_nudge\n"])?.campaignKey == "welcome_nudge")
    }

    @Test("keeps WebEngage's own id as the CEP identity, not as the coupling key")
    func idIsIdentityNotKey() {
        let payload = mapper.map(inAppPayload(experimentId: "exp_9", campaignKey: "welcome_nudge"))

        #expect(payload?.cepCampaignId == "exp_9")
        #expect(payload?.campaignKey == "welcome_nudge")
        #expect(payload?.cepMetadata["experimentId"] == "exp_9")
    }

    @Test("maps nothing when the marketer typed no key")
    func noKeyAtAll() {
        // A WebEngage campaign that is not ours. Mapping it anyway would render Digia's
        // surface on top of a campaign WebEngage is already showing.
        #expect(mapper.map(["experimentId": "exp_1", "title": "Hello"]) == nil)
        #expect(mapper.map(["digiaKey": "   "]) == nil)
        #expect(mapper.map(["digiaKey": 42]) == nil)
    }

    // MARK: - The suppression gate

    @Test("recognises a Digia campaign by either form, and nothing else")
    func isDigiaCampaign() {
        #expect(WebEngagePayloadMapper.isDigiaCampaign(["campaign-key": "welcome_nudge"]))
        #expect(WebEngagePayloadMapper.isDigiaCampaign(["content": template(key: "welcome_nudge")]))

        // Claiming a campaign that is not ours makes it disappear from the customer's app, so
        // the gate must not widen past the two authored forms.
        #expect(!WebEngagePayloadMapper.isDigiaCampaign(["title": "50% off today"]))
        #expect(
            !WebEngagePayloadMapper.isDigiaCampaign([
                "type": "dialog", "command": "SHOW_DIALOG", "viewId": "promo",
            ]),
            "a WebEngage campaign is not ours because it names a view — that vocabulary is gone")
    }

    @Test("claims a digia-config block even when it names no campaign key")
    func gateIsWiderThanTheMapper() {
        // The one place the gate and the mapper disagree on purpose. A block is unambiguously
        // ours, so rendering WebEngage's placeholder underneath it is worse than rendering
        // nothing — but the mapper still cannot produce a payload, and `notificationPrepared`
        // owns the consequence.
        let keyless = ["html": #"<template id="digia-config"><meta name="tier" content="gold"></template>"#]

        #expect(WebEngagePayloadMapper.isDigiaCampaign(keyless))
        #expect(WebEngagePayloadMapper.resolveConfig(keyless) == nil)
    }

    // MARK: - <template id="digia-config">

    /// The HTML form, which exists because WebEngage's in-app custom fields are string-valued:
    /// an HTML body is often the only place structured configuration can go at all.
    private func template(key: String, metas: String = "") -> String {
        """
        <div class="banner">
          <template id="digia-config">
            <meta name="campaign-key" content="\(key)">
        \(metas)
          </template>
        </div>
        """
    }

    @Test("reads the key and the variables out of the digia-config block")
    func templateBlock() {
        let payload = mapper.map([
            "experimentId": "exp_1",
            "html": template(
                key: "welcome_nudge",
                metas: #"    <meta name="user_name" content="Priya"><meta name="tier" content="gold"/>"#),
        ])

        #expect(payload?.campaignKey == "welcome_nudge")
        #expect(payload?.variables == ["user_name": "Priya", "tier": "gold"])
    }

    @Test("matches the block whatever case the tags are typed in, across newlines")
    func templateIsCaseInsensitiveAndSpansLines() {
        // Marketers paste this into a rich-text editor, which reflows and re-cases it, and
        // single quotes are what most editors emit.
        let html = """
            <TEMPLATE ID='digia-config'>
              <META name='Digia_Key'
                    content='welcome_nudge'>
            </TEMPLATE>
            """
        #expect(mapper.map(["html": html])?.campaignKey == "welcome_nudge")
    }

    @Test("does not read an attribute spelled NAME= rather than name=")
    func attributeNamesAreCaseSensitive() {
        // Not a preference — a limitation, pinned so it stays identical on all four stacks.
        // Dart, Kotlin and ObjC all key the parsed attributes verbatim and look up `name` and
        // `content` in lowercase, so an uppercase spelling finds nothing. Relaxing it here
        // alone would make a campaign render on iOS and nowhere else, which is worse than
        // failing the same way everywhere.
        let html = #"<template id="digia-config"><META NAME="digiaKey" CONTENT="k"></template>"#
        #expect(mapper.map(["html": html]) == nil)
    }

    @Test("unescapes attribute values the editor encoded")
    func templateUnescapesAttributes() {
        // A rich-text editor escapes quotes and ampersands on save. Interpolating the escape
        // sequence verbatim renders `Priya &amp; co` to the user.
        let payload = mapper.map([
            "html": template(
                key: "welcome_nudge",
                metas: #"    <meta name="greeting" content="Priya &amp; co &quot;VIP&quot;">"#),
        ])

        #expect(payload?.variables == ["greeting": #"Priya & co "VIP""#])
    }

    @Test("ignores a block that names no campaign key")
    func templateWithoutKey() {
        let html = #"<template id="digia-config"><meta name="user_name" content="Priya"></template>"#
        #expect(mapper.map(["html": html]) == nil, "variables alone are not a campaign")
    }

    @Test("prefers a top-level key over the block, and falls back to the block for variables")
    func topLevelBeatsTemplate() {
        // Key and variables resolve independently. A marketer who lifted the key out of the
        // block into a field, and left the variable metas where they were, still gets both.
        let payload = mapper.map([
            "digiaKey": "from_field",
            "html": template(key: "from_block", metas: #"    <meta name="tier" content="gold">"#),
        ])

        #expect(payload?.campaignKey == "from_field")
        #expect(payload?.variables == ["tier": "gold"])
    }

    @Test("a top-level variables block shuts the meta fallback off")
    func topLevelVariablesBeatTemplateMetas() {
        let payload = mapper.map([
            "digiaKey": "k",
            "variables": ["tier": "platinum"],
            "html": template(key: "from_block", metas: #"    <meta name="tier" content="gold">"#),
        ])

        #expect(payload?.variables == ["tier": "platinum"], "never merged, so the stale meta stays out")
    }

    // MARK: - Variables

    /// `variables` built by parsing JSON text rather than written as a Swift dictionary
    /// literal, because that is how it arrives: the SDK hands over a serialised blob and every
    /// number comes back an `NSNumber`, which bridges to `Bool` as readily as to `Int`. A
    /// fixture written with native `Int`s carries real `Int`s, which do *not* bridge to `Bool`
    /// — so a test written that way passes against the bug it exists to catch.
    private func variables(_ json: String, key: String = "variables") -> [String: String]? {
        var payload = inAppPayload()
        payload[key] = try! JSONSerialization.jsonObject(with: Data(json.utf8))
        return mapper.map(payload)?.variables
    }

    @Test("renders a number as the number the marketer typed, and a boolean as a boolean")
    func numbersAreNotBooleans() {
        #expect(
            variables(#"{"count":1,"zero":0,"price":2.5,"onSale":true}"#)
                == ["count": "1", "zero": "0", "price": "2.5", "onSale": "true"])
    }

    @Test("drops values that have no flat form")
    func dropsNonScalars() {
        #expect(
            variables(#"{"tags":["a"],"nested":{"x":1},"blank":"","gone":null,"keep":"y"}"#)
                == ["keep": "y"])
    }

    @Test("carries no variables when the marketer authored none")
    func noVariables() {
        #expect(variables("{}") == nil, "an empty map is not variables")
        #expect(mapper.map(inAppPayload())?.variables == nil)
        #expect(mapper.map(["digiaKey": "k", "variables": 5])?.variables == nil)
    }

    @Test("prefers variables over the older args, and never merges the two")
    func variablesBeatArgs() {
        #expect(
            mapper.map([
                "digiaKey": "k",
                "variables": ["name": "Priya"],
                "args": ["name": "Stale", "tier": "gold"],
            ])?.variables == ["name": "Priya"],
            "a stale args block must not leak a key that variables dropped")

        #expect(
            variables(#"{"name":"Priya"}"#, key: "args") == ["name": "Priya"],
            "args is the older spelling, and campaigns authored against it are live")

        // The case that tells first-wins apart from merge: `variables` is an object, so it
        // wins — and then every one of its values turns out to be droppable. The answer is no
        // variables at all. A merging implementation answers `["tier": "gold"]` here, and
        // passes every assertion above.
        #expect(
            mapper.map([
                "digiaKey": "k",
                "variables": ["name": "", "tags": ["a"], "gone": NSNull()],
                "args": ["tier": "gold"],
            ])?.variables == nil)
    }

    @Test("reads variables the dashboard could only store as text")
    func variablesAsSerialisedText() {
        // WebEngage's in-app custom fields are string-valued, so an object typed on the
        // dashboard reaches the mapper as JSON text. Requiring a real object here drops every
        // variable on a campaign authored that way, silently.
        let payload = mapper.map(["digiaKey": "k", "variables": #"{"count":1,"name":"Priya"}"#])
        #expect(payload?.variables == ["count": "1", "name": "Priya"])
    }

    // MARK: - Inline (WEPersonalization)

    @Test("an inline campaign is identified by campaign and property together")
    func inlineIdentity() {
        // One WebEngage campaign can be served into several properties at once. Keyed by
        // campaign alone, the second slot would collide with the first and one of the two
        // would never render.
        let a = mapper.mapInline(
            campaignId: "camp_1", targetViewId: "home_banner",
            customData: ["digiaKey": "welcome_nudge"])
        let b = mapper.mapInline(
            campaignId: "camp_1", targetViewId: "cart_banner",
            customData: ["digiaKey": "welcome_nudge"])

        #expect(a?.campaignKey == "welcome_nudge")
        #expect(a?.cepCampaignId == "camp_1:home_banner")
        #expect(b?.cepCampaignId == "camp_1:cart_banner")
        #expect(a?.cepMetadata["propertyId"] == "home_banner")
        #expect(a?.cepMetadata["experimentId"] == "camp_1")
    }

    @Test("an inline campaign prefers the ids WebEngage supplied over the derived pair")
    func inlineUsesEnvelopeIds() {
        // Dart derives both from the pair because `WECampaignData` hands it nothing else.
        // Here the envelope carries the real ids, and they are what WebEngage's own analytics
        // name the campaign by — deriving over them would file the events under an id
        // WebEngage never issued.
        let payload = mapper.mapInline(
            campaignId: "camp_1", targetViewId: "home_banner",
            customData: ["digiaKey": "welcome_nudge"],
            metadata: ["variationId": "var_7", "propertyId": "prop_3"])

        #expect(payload?.cepMetadata["variationId"] == "var_7")
        #expect(payload?.cepMetadata["propertyId"] == "prop_3")
        #expect(payload?.cepCampaignId == "camp_1:home_banner", "identity stays the pair")
    }

    @Test("an inline campaign with no Digia key maps to nothing")
    func inlineWithoutKey() {
        #expect(
            mapper.mapInline(
                campaignId: "camp_1", targetViewId: "home_banner",
                customData: ["title": "50% off"]) == nil)
    }
}
