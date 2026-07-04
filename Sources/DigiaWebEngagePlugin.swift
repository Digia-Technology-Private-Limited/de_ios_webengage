import Foundation
import DigiaEngage
@preconcurrency import WebEngage

/// Top-level plugin that wires WebEngage in-app and personalization callbacks into Digia's
/// CEP rendering engine on iOS.  Drop-in equivalent of `WebEngagePlugin.kt` on Android.
///
/// **Usage (AppDelegate):**
/// ```swift
/// import DigiaEngageWebEngage
///
/// WebEngage.sharedInstance().application(
///     application,
///     didFinishLaunchingWithOptions: launchOptions,
///     notificationDelegate: WebEngagePlugin.notificationDelegate
/// )
/// ```
/// **Usage (app entry-point):**
/// ```swift
/// Digia.register(WebEngagePlugin())
/// ```
@MainActor
public final class DigiaWebEngagePlugin: DigiaCEPPlugin {

    // MARK: - State

    public let identifier: String = "webengage"

    private let bridge: WebEngageBridgeProtocol
    private let mapper: WebEngagePayloadMapper
    private let config: WebEngagePluginConfig
    private let cache:  InAppDataCache
    private lazy var dispatcher = WebEngageEventDispatcher(bridge: bridge, cache: cache)

    private weak var delegate: DigiaCEPDelegate?
    private var callbacksRegistered: Bool = false

    // MARK: - AppDelegate hook

    /// The in-app notification delegate that must be passed to WebEngage at SDK
    /// initialisation time in your `AppDelegate`:
    /// ```swift
    /// WebEngage.sharedInstance().application(
    ///     application,
    ///     didFinishLaunchingWithOptions: launchOptions,
    ///     notificationDelegate: WebEngagePlugin.notificationDelegate
    /// )
    /// ```
    /// WebEngage keeps only a **weak** reference to this object; the shared
    /// bridge singleton at class scope ensures its lifetime.
    nonisolated public static let notificationDelegate: any WEGInAppNotificationProtocol = WebEngageSdkBridge.shared

    // MARK: - Init

    /// Designated public initialiser.
    public convenience init(config: WebEngagePluginConfig = WebEngagePluginConfig()) {
        let cache  = InAppDataCache()
        // Reuse the same singleton that AppDelegate registered with WebEngage SDK.
        let bridge = WebEngageSdkBridge.shared
        bridge.config = config
        let mapper = WebEngagePayloadMapper(config: config)
        self.init(bridge: bridge, mapper: mapper, config: config, cache: cache)
    }

    /// Internal / test initialiser with injectable bridge and mapper.
    internal init(
        bridge: WebEngageBridgeProtocol,
        mapper: WebEngagePayloadMapper,
        config: WebEngagePluginConfig,
        cache:  InAppDataCache
    ) {
        self.bridge  = bridge
        self.mapper  = mapper
        self.config  = config
        self.cache   = cache
    }

    // MARK: - DigiaCEPPlugin

    public func setup(delegate: DigiaCEPDelegate) {
        logDebug("setup start diagnostics=\(config.diagnosticsEnabled)")
        self.delegate = delegate
        bridge.registerInAppListener(
            onPayload:    { [weak self] data in Task { @MainActor in self?.dispatchMappedPayloads(data) } },
            onInvalidate: { [weak self] id   in Task { @MainActor in self?.dispatchInvalidation(campaignID: id) } }
        )
        bridge.registerInlineListener { [weak self] cid, tvid, custom, meta in
            Task { @MainActor in
                self?.dispatchInlinePayload(campaignId: cid, targetViewId: tvid,
                                            customData: custom, metadata: meta)
            }
        }
        callbacksRegistered = true
        logDebug("setup complete delegateAttached=\(self.delegate != nil)")
    }

    public func notifyEvent(_ event: DigiaExperienceEvent, payload: CEPTriggerPayload) {
        logDebug("notify_event payloadId=\(payload.cepCampaignId)")
        dispatcher.dispatch(event: event, payload: payload)
    }

    public func forwardScreen(_ name: String) {
        logDebug("forward_screen name=\(name)")
        dispatcher.forwardScreen(name)
    }

    /// `registerPlaceholder` — default no-op; override if you track inline slot registrations.
    public func registerPlaceholder(propertyID: String) -> Int? { nil }

    /// `deregisterPlaceholder` — default no-op.
    public func deregisterPlaceholder(_ id: Int) {}

    public func teardown() {
        logDebug("teardown start")
        bridge.unregisterInAppListener()
        bridge.unregisterInlineListener()
        cache.clear()
        callbacksRegistered = false
        delegate = nil
        logDebug("teardown complete")
    }

    public func healthCheck() -> DiagnosticReport {
        let hasDelegate = delegate != nil
        let isAvailable = bridge.isAvailable()
        let isHealthy   = hasDelegate && isAvailable
        return DiagnosticReport(
            isHealthy: isHealthy,
            issue: isHealthy ? nil : "webengage plugin not fully wired",
            resolution: isHealthy ? nil : "Call setup(delegate:) after WebEngage SDK initialises",
            metadata: [
                "identifier":           identifier,
                "delegateAttached":     String(hasDelegate),
                "bridgeAvailable":      String(isAvailable),
                "callbacksRegistered":  String(callbacksRegistered),
                "diagnosticsEnabled":   String(config.diagnosticsEnabled),
            ]
        )
    }

    // MARK: - Private dispatch

    private func dispatchMappedPayloads(_ rawPayload: [String: Any]) {
        guard let activeDelegate = delegate else {
            logWarning("inapp_payload_dropped reason=delegate_unavailable"); return
        }
        let payloads = mapper.map(rawPayload)
        guard !payloads.isEmpty else {
            logWarning("inapp_payload_dropped reason=mapper_returned_empty"); return
        }
        payloads.forEach { payload in
            logDebug("dispatch_inapp payloadId=\(payload.cepCampaignId)")
            if !activeDelegate.onCampaignTriggered(payload) {
                bridge.releaseCampaignGate(payload.cepMetadata["experimentId"] ?? payload.cepCampaignId)
            }
        }
    }

    private func dispatchInlinePayload(
        campaignId:  String,
        targetViewId: String,
        customData:  [String: Any],
        metadata:    [String: Any]
    ) {
        guard let activeDelegate = delegate else {
            logWarning("inline_payload_dropped campaignId=\(campaignId) reason=delegate_unavailable"); return
        }
        guard let payload = mapper.mapInline(
            campaignId: campaignId,
            targetViewId: targetViewId,
            customData: customData,
            metadata: metadata
        ) else { return }
        logDebug("dispatch_inline payloadId=\(payload.cepCampaignId)")
        if !activeDelegate.onCampaignTriggered(payload) {
            bridge.releaseCampaignGate(payload.cepMetadata["experimentId"] ?? payload.cepCampaignId)
        }
    }

    private func dispatchInvalidation(campaignID: String) {
        guard let activeDelegate = delegate else {
            logWarning("invalidation_dropped campaignID=\(campaignID) reason=delegate_unavailable"); return
        }
        logDebug("dispatch_invalidation campaignID=\(campaignID)")
        activeDelegate.onCampaignInvalidated(campaignID)
    }

    // MARK: - Logging

    private func logDebug(_ message: String) {
        if config.diagnosticsEnabled { NSLog("[DigiaWEPlugin] \(message)") }
    }

    private func logWarning(_ message: String) {
        NSLog("[DigiaWEPlugin] WARNING: \(message)")
    }
}
