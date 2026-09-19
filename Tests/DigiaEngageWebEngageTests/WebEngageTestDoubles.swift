@testable import DigiaEngage
@testable import DigiaEngageWebEngage
import Foundation

/// Stands in for Digia core.
///
/// Built on the real ``PresentationController``, so the contract's own
/// guarantees — exactly-once settlement, no signals after the outcome,
/// `holdReleased` settling at or before `outcome` — hold in these tests rather
/// than being re-implemented by a fake that could drift from them.
@MainActor
final class FakeCEPHost: DigiaCEPHost {
    /// When set, `deliver` returns an already-settled presentation.
    var syncDrop: DropReason?

    private(set) var delivered: [CEPTriggerPayload] = []
    private(set) var controllers: [PresentationController] = []
    private var nextId = 0

    init(syncDrop: DropReason? = nil) {
        self.syncDrop = syncDrop
    }

    func deliver(_ trigger: CEPTriggerPayload) -> CampaignPresentation {
        delivered.append(trigger)
        nextId += 1
        let controller = PresentationController(id: "p-\(nextId)", trigger: trigger)
        controllers.append(controller)
        if let syncDrop {
            controller.settle(.dropped(reason: syncDrop, detail: nil))
        }
        return controller.presentation
    }

    /// The controller for the most recent delivery — the test's handle on core.
    var last: PresentationController { controllers[controllers.count - 1] }
}

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
    private(set) var inAppListenerRegistered = false
    private(set) var inAppListenerUnregistered = false

    private var onPayload: (([String: Any]) -> Void)?
    private var onInvalidate: ((String) -> Void)?

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

    func releaseGate(experimentId: String) { releasedGates.append(experimentId) }

    func unregisterInAppListener() {
        onPayload = nil
        onInvalidate = nil
        inAppListenerUnregistered = true
    }

    func unregisterInlineListener() {}

    func isAvailable() -> Bool { true }
}

/// A `notificationPrepared` payload for a modal campaign.
func inAppPayload(
    experimentId: String = "exp_1",
    viewId: String = "onboarding_tip",
    variationId: String = "var_1"
) -> [String: Any] {
    [
        "experimentId": experimentId,
        "command": "SHOW_DIALOG",
        "viewId": viewId,
        "variationId": variationId,
    ]
}

/// A `notificationPrepared` payload for an inline campaign.
func inlinePayload(
    experimentId: String = "exp_inline",
    placementKey: String = "home_banner",
    viewId: String = "banner_view"
) -> [String: Any] {
    [
        "experimentId": experimentId,
        "type": "inline",
        "placementKey": placementKey,
        "viewId": viewId,
    ]
}

/// Lets main-actor continuations resumed by a settlement actually run.
///
/// The plugin binds its terminal work to `await presentation.outcome.value`, so
/// a settlement made by a test resumes a task that runs on the *next* main-actor
/// turn. Synchronous drops and plugin-initiated terminations do not need this.
func drainMainActor(_ turns: Int = 5) async {
    for _ in 0..<turns { await Task.yield() }
}
