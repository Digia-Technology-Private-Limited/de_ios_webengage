@testable import DigiaEngage
@testable import DigiaEngageWebEngage
import Foundation
import Testing

/// What the marketer's `args` become once they reach a campaign config.
///
/// The failure these exist to catch is silent: a variable that interpolates the wrong literal
/// renders a campaign that looks fine and says something false. Every JSON number arrives from
/// the WebEngage SDK as an NSNumber, and an NSNumber bridges to `Bool` as readily as to `Int`,
/// so a naive `case let b as Bool` above the numeric cases claims every `1` is `true`.
@MainActor
struct WebEngagePayloadMapperTests {

    private let mapper = WebEngagePayloadMapper(
        config: WebEngagePluginConfig(diagnosticsEnabled: false))

    /// `args` as a JSON string, which is how it reaches the mapper in production: the SDK
    /// hands over a serialised blob, `normalizeArgs` runs it through JSONSerialization, and
    /// every number comes back an NSNumber. A Swift-native `[String: Any]` literal would
    /// carry real `Int`s, which do *not* bridge to `Bool` — so a test written that way passes
    /// against the bug.
    private func variables(_ argsJson: String) -> [String: String]? {
        var payload = inAppPayload()
        payload["args"] = argsJson
        return mapper.map(payload).first?.variables
    }

    @Test("renders a number as the number the marketer typed")
    func numbersAreNotBooleans() {
        #expect(
            variables(#"{"count":1,"zero":0,"price":2.5,"onSale":true}"#)
                == ["count": "1", "zero": "0", "price": "2.5", "onSale": "true"])
    }

    @Test("drops values that have no flat form")
    func dropsNonScalars() {
        #expect(variables(#"{"tags":["a"],"nested":{"x":1},"gone":null,"keep":"y"}"#)
            == ["keep": "y"])
    }

    @Test("carries no variables when the marketer authored none")
    func noVariables() {
        #expect(variables("{}") == nil)
    }
}
