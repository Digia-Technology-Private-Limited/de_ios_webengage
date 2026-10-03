@testable import DigiaEngage
@testable import DigiaEngageWebEngage
import Foundation

/// Records every WebEngage call the plugin makes, and lets a test push the
/// callbacks WebEngage would push.
final class FakeWebEngageBridge: WebEngageBridgeProtocol, @unchecked Sendable {
    struct SystemEvent {
        let name: String
        let systemData: [String: Any]
    }

    private(set) var events: [SystemEvent] = []
    private(set) var navigatedScreens: [String] = []
    private(set) var releasedGates: [String] = []
    private(set) var delayedGateReleases: [String] = []
    private(set) var inAppListenerRegistered = false
    private(set) var inAppListenerUnregistered = false

    private var onPayload: (([String: Any]) -> Void)?
    private var onInvalidate: ((String) -> Void)?

    /// Runs from inside ``releaseGate(experimentId:)``, so a test can make
    /// WebEngage's own release call misbehave (scenario C5).
    var onReleaseGate: ((String) -> Void)?

    /// Names only — what a test usually asserts on.
    var eventNames: [String] { events.map(\.name) }

    func eventsNamed(_ name: String) -> [SystemEvent] { events.filter { $0.name == name } }

    // Pushes WebEngage's own callbacks.
    func emitPrepared(_ payload: [String: Any]) { onPayload?(payload) }
    func emitDismissed(experimentId: String) { onInvalidate?(experimentId) }

    // MARK: - WebEngageBridgeProtocol

    func registerInAppListener(
        onPayload: @escaping ([String: Any]) -> Void,
        onInvalidate: @escaping (String) -> Void
    ) {
        self.onPayload = onPayload
        self.onInvalidate = onInvalidate
        inAppListenerRegistered = true
    }

    func registerInlineListener(
        onInlineCampaign: @escaping (String, String, [String: Any], [String: Any]) -> Void
    ) {}

    func trackSystemEvent(eventName: String, systemData: [String: Any], eventData: [String: Any]) {
        events.append(SystemEvent(name: eventName, systemData: systemData))
    }

    func navigateScreen(_ name: String) { navigatedScreens.append(name) }

    func releaseGate(experimentId: String) {
        releasedGates.append(experimentId)
        onReleaseGate?(experimentId)
    }

    /// Runs at once: timing is the real bridge's business (see
    /// `WebEngageSdkBridgeTests`), the plugin only chooses the path.
    func notifyDismissed(experimentId: String) {
        delayedGateReleases.append(experimentId)
        releaseGate(experimentId: experimentId)
    }

    func unregisterInAppListener() {
        onPayload = nil
        onInvalidate = nil
        inAppListenerUnregistered = true
    }

    func unregisterInlineListener() {}

    func isAvailable() -> Bool { true }
}

/// A `notificationPrepared` payload for a Digia campaign.
func inAppPayload(
    experimentId: String = "exp_1",
    campaignKey: String = "onboarding_tip",
    variationId: String = "var_1"
) -> [String: Any] {
    [
        "experimentId": experimentId,
        "digiaKey": campaignKey,
        "variationId": variationId,
    ]
}


/// A manual clock and timer for the pending buffer: `advance` fires due timers.
@MainActor
final class FakeClock {
    var now = Date(timeIntervalSince1970: 0)
    private var timers: [(id: Int, due: Date, work: @MainActor () -> Void)] = []
    private var nextId = 0

    func schedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
        nextId += 1
        let id = nextId
        timers.append((id, now.addingTimeInterval(delay), work))
        return { [weak self] in self?.timers.removeAll { $0.id == id } }
    }

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        while let index = timers.firstIndex(where: { $0.due <= now }) {
            timers.remove(at: index).work()
        }
    }
}
